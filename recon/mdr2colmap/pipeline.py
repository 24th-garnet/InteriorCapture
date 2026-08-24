"""サーバ側の高精度化パイプライン（目標 5 分）。

不動産営業の参考資料を作ることが目的。用途に照らして手法を選んだ:

- **3DGS を主成果物にする。** 実測で最高品質（PSNR 24.8）で、
  テクスチャ付きメッシュ（18.8）を大きく上回る。ガウシアンはメッシュに
  縛られないので、これまで品質の上限を決めていた形状誤差の影響を受けにくい。
  撮影軌跡から離れると破綻するという弱点は、内見が「人が歩く経路を見せる」
  ものである以上、station 制約ビューアと組み合わせれば問題にならない。

- **TSDF 再融合とテクスチャ焼き込みは行わない。** TSDF は形状誤差を
  5.49→4.40mm に改善するが面数が 2 倍になり、xatlas の UV 展開が
  5 分の予算を食い潰す。テクスチャ品質も 3DGS に及ばない。
  テクスチャ付きメッシュは端末側（79 秒）の役割として残す。

- **ポーズ精密化は行う。** 12 秒で系統的偏りを 10.4→3.7mm に減らせる。

- **学習解像度は 640 に固定する。** 実測では 960 で +0.21 dB、1920 で +0.42 dB
  改善するが、960 は 5 分要件を 53 秒超過する。実機のツアービューアで
  動かして確認した結果、640 で品質は十分と判断した。
  高解像度への対応は後付けの課題として切り離す。
"""

from __future__ import annotations

import copy
import dataclasses
import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from . import colmap, pointcloud, refine, tour
from .mdr import Bundle
from .mesh import read_ply_mesh

#: 学習解像度。本アプリはこの 1 通りのみに対応する（モジュール冒頭の説明を参照）。
TRAIN_RESOLUTION = 640
#: ガウシアン数の上限。
#:
#: 25 万を既定にする。50 万との差は PSNR 0.04 dB で、静止画の等倍比較では
#: 区別できない。ツアービューアで動かして比較したところ「僅かに劣るが許容範囲」
#: との評価だった。得られるものは大きい:
#:   3DGS 学習   260 秒 → 179 秒（81 秒短縮）
#:   ファイル    112 MB → 56 MB（顧客への共有時の転送量が半分）
#:   5 分要件の余裕  18 秒 → 101 秒
#:
#: 余裕が 18 秒しかないと、他の処理が同時に走るだけで要件を超過する
#: （実測で 3DGS が 262→302 秒に伸びた例がある）。変動に耐える余裕を
#: 持たせる意味でも 25 万が妥当。
#: 品質を優先する場合は --max-splats 500000 で戻せる。
MAX_SPLATS = 250_000
#: iteration。5K では 0.97 dB 落ちるのでここが下限。
TRAIN_ITERS = 10_000


@dataclass
class Stage:
    name: str
    seconds: float
    detail: str = ""


@dataclass
class PipelineResult:
    scene_dir: Path
    tour_path: Path
    splat_path: Path | None = None
    stages: list[Stage] = field(default_factory=list)

    @property
    def total(self) -> float:
        return sum(s.seconds for s in self.stages)


def run(
    bundle_path: str | Path,
    output: str | Path,
    conf_min: int = 2,
    voxel: float = 0.02,
    refine_poses: bool = True,
    station_spacing: float = 1.0,
    log=print,
) -> PipelineResult:
    """MDR バンドルから 3DGS 学習用のシーンとツアー定義を作る。

    3DGS の学習自体は Brush（外部プロセス）に任せる。ここはその手前まで。
    """
    out = Path(output)
    sparse = out / "sparse" / "0"
    images = out / "images"
    sparse.mkdir(parents=True, exist_ok=True)
    images.mkdir(parents=True, exist_ok=True)

    stages: list[Stage] = []
    t0 = time.time()
    bundle = Bundle(bundle_path)
    stages.append(Stage("読み込み", time.time() - t0, f"{len(bundle)} フレーム"))
    log(f"  読み込み {stages[-1].seconds:.1f}s  ({len(bundle)} フレーム)")

    if refine_poses:
        t = time.time()
        mesh = read_ply_mesh(Path(bundle_path) / "mesh.ply")
        poses, stats = refine.refine(bundle, mesh, conf_min=conf_min)
        before = np.median([s.before for s in stats]) * 1000
        after = np.median([s.after for s in stats]) * 1000
        stages.append(Stage("ポーズ精密化", time.time() - t, f"残差 {before:.1f}→{after:.1f}mm"))
        log(f"  ポーズ精密化 {stages[-1].seconds:.1f}s  (残差 {before:.1f}→{after:.1f}mm)")
        bundle = copy.copy(bundle)
        bundle.frames = [
            dataclasses.replace(f, c2w_arkit=p) for f, p in zip(bundle.frames, poses)
        ]

    frames = bundle.frames
    names = [bundle.image_name(f.index) for f in frames]
    width, height = bundle.manifest.video_wh

    t = time.time()
    colmap.write_cameras_bin(sparse / "cameras.bin", frames, width, height)
    colmap.write_images_bin(sparse / "images.bin", frames, names)
    for f, name in zip(frames, names):
        dst = images / name
        if dst.exists() or dst.is_symlink():
            dst.unlink()
        dst.symlink_to(bundle.image_path(f.index).resolve())
    stages.append(Stage("COLMAP 書き出し", time.time() - t, f"{len(frames)} カメラ"))
    log(f"  COLMAP 書き出し {stages[-1].seconds:.1f}s")

    t = time.time()
    xyz, rgb = pointcloud.build(bundle, frames, conf_min=conf_min, voxel=voxel)
    colmap.write_points3d_ply(sparse / "points3D.ply", xyz, rgb)
    stages.append(Stage("初期点群", time.time() - t, f"{len(xyz):,} 点"))
    log(f"  初期点群 {stages[-1].seconds:.1f}s  ({len(xyz):,} 点)")

    t = time.time()
    tr = tour.extract(bundle, spacing=station_spacing)
    tour_path = out / "tour.json"
    tour_path.write_text(tr.to_json())
    stages.append(Stage("station 抽出", time.time() - t, f"{len(tr.stations)} 箇所"))
    log(f"  station 抽出 {stages[-1].seconds:.1f}s  ({len(tr.stations)} 箇所)")

    return PipelineResult(scene_dir=out, tour_path=tour_path, stages=stages)


def train(
    scene_dir: str | Path,
    brush: str | Path,
    max_splats: int = MAX_SPLATS,
    iterations: int = TRAIN_ITERS,
    eval_split_every: int = 50,
    log=print,
) -> tuple[Path | None, float]:
    """Brush で 3DGS を学習する。戻り値は (splat の PLY, 所要秒)。

    解像度は `TRAIN_RESOLUTION` に固定する。引数で変えられるようにしていないのは、
    5 分要件の下では 640 以外を選ぶ理由がないため（モジュール冒頭の説明を参照）。
    """
    import subprocess

    scene = Path(scene_dir)
    gs = scene / "gs"
    if gs.exists():
        shutil.rmtree(gs)

    cmd = [
        str(brush), str(scene),
        "--max-resolution", str(TRAIN_RESOLUTION),
        "--max-splats", str(max_splats),
        "--total-train-iters", str(iterations),
        "--eval-split-every", str(eval_split_every),
        "--eval-every", str(iterations),
        "--eval-save-to-disk",
        "--export-every", str(iterations),
        "--export-path", str(gs) + "/",
    ]
    t = time.time()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    elapsed = time.time() - t

    plys = sorted(gs.glob("*.ply")) if gs.exists() else []
    if not plys:
        log(f"  3DGS 学習が出力を残しませんでした（{elapsed:.0f}s）")
        if proc.stderr.strip():
            log("  " + proc.stderr.strip().splitlines()[-1])
        return None, elapsed

    log(f"  3DGS 学習 {elapsed:.0f}s  ({plys[0].name})")
    return plys[0], elapsed


def run_all(
    bundle_path: str | Path,
    output: str | Path,
    brush: str | Path,
    log=print,
    **kwargs,
) -> PipelineResult:
    """前処理から 3DGS 学習まで通しで実行する。"""
    result = run(bundle_path, output, log=log, **kwargs)
    splat, seconds = train(result.scene_dir, brush, log=log)
    result.splat_path = splat
    result.stages.append(Stage("3DGS 学習", seconds, splat.name if splat else "失敗"))
    return result
