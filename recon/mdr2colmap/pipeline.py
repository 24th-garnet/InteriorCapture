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
#: 25 万でも 50 万との差は PSNR 0.04 dB で、ツアービューアで動かした評価は
#: 「僅かに劣るが許容範囲」だった。25 万なら学習が 81 秒短く、ファイルも半分。
#: それでも 50 万を既定に置くのは、25 万での完走実績がないため。
#:
#: 当初 25 万を既定にしたところ学習が落ちたので「上限に早く達するのが原因」と
#: 判断したが、これは誤りだった。同じ panic は 50 万でも別シーンで起きる
#: （`TRAIN_ATTEMPTS` を参照）。上限値とは無関係な競合状態であり、
#: 25 万が落ちたのはたまたまである可能性が高い。
#:
#: リトライを入れたので 25 万も再評価する価値はあるが、
#: 実測が取れるまでは実績のある 50 万を既定に置く。
MAX_SPLATS = 500_000
#: iteration。5K では 0.97 dB 落ちるのでここが下限。
TRAIN_ITERS = 10_000
#: 学習の試行回数。
#:
#: Brush が依存する burn の融合エンジン (burn-fusion) には競合状態があり、
#: 学習が確率的に落ちる:
#:
#:   burn_cubecl_fusion::engine::launch::output.rs:207
#:     called `Option::unwrap()` on a `None` value
#:
#: 同一シーン・同一引数で落ちたり通ったりする。実測では 408 フレームの部屋で
#: 1 回目が 54 秒で落ち、2 回目が 300 秒で完走した。上限値やシーンとは相関せず
#: （50 万で 4 連続成功した後、別シーンの 50 万で落ちた）、再現条件は掴めていない。
#: burn 側にも修正はなく、公開されている回避策は融合の無効化のみ (tracel-ai/burn#4347)。
#: 融合は Brush のバックエンド型に埋め込まれている
#: (impl SplatOps for Fusion<MainBackendBase>) ため、機能フラグでは外せない。
#:
#: 落ちるのは学習の序盤（実測 32〜54 秒）なので、捨てる時間は 1 分弱で済む。
#: 失敗は PLY が出ないことで確実に検知できる。
TRAIN_ATTEMPTS = 3


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
    attempts: int = TRAIN_ATTEMPTS,
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
    for attempt in range(1, attempts + 1):
        if gs.exists():
            shutil.rmtree(gs)
        proc = subprocess.run(cmd, capture_output=True, text=True)
        plys = sorted(gs.glob("*.ply")) if gs.exists() else []
        if plys:
            elapsed = time.time() - t
            note = f"（{attempt} 回目で成功）" if attempt > 1 else ""
            log(f"  3DGS 学習 {elapsed:.0f}s  ({plys[0].name}){note}")
            return plys[0], elapsed

        tail = proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else "(stderr なし)"
        if attempt < attempts:
            log(f"  3DGS 学習 {attempt} 回目が落ちました。再試行します: {tail[:110]}")

    elapsed = time.time() - t
    log(f"  3DGS 学習が {attempts} 回とも失敗しました（{elapsed:.0f}s）")
    log("  " + tail)
    return None, elapsed


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
