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
"""

from __future__ import annotations

import copy
import dataclasses
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from . import colmap, pointcloud, refine, tour
from .mdr import Bundle
from .mesh import read_ply_mesh


@dataclass
class Stage:
    name: str
    seconds: float
    detail: str = ""


@dataclass
class PipelineResult:
    scene_dir: Path
    tour_path: Path
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
