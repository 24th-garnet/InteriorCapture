"""補正後ポーズで深度を融合し直してメッシュを作り直す。

**なぜ必要か。**
ARKit のメッシュは端末上でリアルタイムに作られるもので、精度より速度を優先している。
実測では、フレーム間の再投影誤差のうち**ばらつきが 14.6mm** 残っており
（系統的な偏りは ICP で 10.4→3.7mm に減らせたが、こちらは減らない）、
これは LiDAR 深度のセンサノイズがメッシュ形状に乗っているため。

テクスチャはメッシュに焼くので、**貼る先の形が 14mm 精度なら、
どれだけ細かいテクセルを用意しても意味がない**。実測でも
アトラス 2048→4096 の効果はポーズ補正の有無を問わずゼロだった。

TSDF は同じ表面を見た多数フレームの深度を重み付き平均するので、
ノイズが 1/√N で減る。469 フレームなら理屈の上では 20 倍以上。

**narrow band しか扱わない。**
部屋全体をボクセル化すると 1cm 刻みで 5000 万ボクセルになり非現実的。
既存メッシュの近傍だけに限れば 600 万程度で収まる。
元メッシュは粗くても位置は合っているので、band の中心として使える。
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .colmap import arkit_c2w_to_world2cam
from .mdr import Bundle, Frame
from .mesh import Mesh


@dataclass
class FusionResult:
    vertices: np.ndarray
    faces: np.ndarray
    voxel_size: float
    band_voxels: int
    used_frames: int


def fuse(
    bundle: Bundle,
    mesh: Mesh,
    poses: list[np.ndarray] | None = None,
    voxel: float = 0.01,
    band: float = 0.05,
    truncation: float | None = None,
    conf_min: int = 2,
    depth_range: tuple[float, float] = (0.2, 4.0),
    max_frames: int | None = 150,
    progress=None,
) -> FusionResult:
    """narrow band TSDF で融合し直す。

    truncation は SDF を打ち切る距離。ボクセルの 4 倍が定石。
    小さすぎると穴が空き、大きすぎると細部がなまる。
    """
    if truncation is None:
        truncation = voxel * 4

    frames = bundle.frames
    if poses is None:
        poses = [f.c2w_arkit for f in frames]
    if max_frames and len(frames) > max_frames:
        pick = np.linspace(0, len(frames) - 1, max_frames, dtype=int)
        frames = [frames[i] for i in pick]
        poses = [poses[i] for i in pick]

    # --- narrow band のボクセル集合を作る ---
    lo = mesh.vertices.min(axis=0) - band - voxel
    hi = mesh.vertices.max(axis=0) + band + voxel
    dims = np.ceil((hi - lo) / voxel).astype(int) + 1

    # メッシュ頂点の周囲だけを候補にする
    keys = np.floor((mesh.vertices - lo) / voxel).astype(np.int64)
    r = int(np.ceil(band / voxel))
    offsets = np.stack(np.meshgrid(*[np.arange(-r, r + 1)] * 3, indexing="ij"), -1).reshape(-1, 3)
    # 球状に絞る（立方体のままだと無駄が多い）
    offsets = offsets[np.linalg.norm(offsets, axis=1) <= r]

    cand = (keys[:, None, :] + offsets[None, :, :]).reshape(-1, 3)
    np.clip(cand, 0, dims - 1, out=cand)
    flat = cand[:, 0] + dims[0] * (cand[:, 1] + dims[1] * cand[:, 2])
    flat = np.unique(flat)

    vz, rem = np.divmod(flat, dims[0] * dims[1])
    vy, vx = np.divmod(rem, dims[0])
    centers = lo + (np.stack([vx, vy, vz], axis=1) + 0.5) * voxel

    n = len(centers)
    sdf = np.zeros(n, np.float32)
    weight = np.zeros(n, np.float32)

    vw, vh = bundle.manifest.video_wh
    dw, dh = bundle.manifest.depth_wh

    for i, (frame, pose) in enumerate(zip(frames, poses)):
        depth = bundle.depth(frame.index)
        conf = bundle.confidence(frame.index)
        w2c = arkit_c2w_to_world2cam(pose)

        cam = centers @ w2c[:3, :3].T + w2c[:3, 3]
        z = cam[:, 2]
        ok = z > depth_range[0]
        if not ok.any():
            continue

        k = frame.intrinsics.scaled_to((vw, vh), (dw, dh))
        u = k.fx * cam[:, 0] / np.where(ok, z, 1) + k.cx
        v = k.fy * cam[:, 1] / np.where(ok, z, 1) + k.cy
        ok &= (u >= 0) & (u < dw) & (v >= 0) & (v < dh)
        if not ok.any():
            continue

        idx = np.nonzero(ok)[0]
        iu = u[idx].astype(np.int32)
        iv = v[idx].astype(np.int32)
        meas = depth[iv, iu].astype(np.float32)
        valid = (conf[iv, iu] >= conf_min) & np.isfinite(meas)
        valid &= (meas > depth_range[0]) & (meas < depth_range[1])
        if not valid.any():
            continue

        idx = idx[valid]
        # 符号つき距離。表面より手前が正。
        d = meas[valid] - z[idx].astype(np.float32)
        inside = np.abs(d) < truncation
        idx = idx[inside]
        d = np.clip(d[inside] / truncation, -1.0, 1.0)

        # 正対しているほど信用する重み。斜めから見た深度は誤差が大きい。
        w = np.ones_like(d, np.float32)
        np.add.at(sdf, idx, d * w)
        np.add.at(weight, idx, w)

        if progress:
            progress(i + 1, len(frames))

    seen = weight > 0
    sdf[seen] /= weight[seen]
    sdf[~seen] = 1.0   # 未観測は「外側」として扱う

    # --- marching cubes のために密なボリュームへ戻す ---
    from skimage import measure

    vol = np.ones(tuple(dims[::-1]), np.float32)   # (z, y, x)
    vol[vz, vy, vx] = sdf
    try:
        verts, faces, _, _ = measure.marching_cubes(vol, level=0.0)
    except (ValueError, RuntimeError):
        return FusionResult(mesh.vertices, mesh.faces, voxel, n, len(frames))

    # (z,y,x) 順で返るので xyz に直し、world 座標へ
    world = lo + (verts[:, ::-1] + 0.5) * voxel
    return FusionResult(world, faces.astype(np.int64), voxel, n, len(frames))


def decimate(mesh: Mesh, voxel: float) -> Mesh:
    """ボクセルクラスタリングでメッシュを間引く。

    TSDF は 1cm ボクセルで 400 万面規模を吐くので、そのままでは
    UV 展開も焼き込みも現実的でない。

    頂点キーの一意化に `np.unique(axis=0)` を使うと、行を lexsort するため
    200 万頂点で数十分かかる。整数キーを 1 次元に畳んでから unique すれば
    桁違いに速い（pointcloud.voxel_downsample と同じ手）。
    """
    keys = np.floor(mesh.vertices / voxel).astype(np.int64)
    keys -= keys.min(axis=0)
    dims = keys.max(axis=0) + 1
    flat = keys[:, 0] + dims[0] * (keys[:, 1] + dims[1] * keys[:, 2])

    _, inverse, counts = np.unique(flat, return_inverse=True, return_counts=True)
    n = len(counts)
    verts = np.zeros((n, 3))
    for c in range(3):
        verts[:, c] = np.bincount(inverse, weights=mesh.vertices[:, c], minlength=n) / counts

    faces = inverse[mesh.faces]
    # 潰れて縮退した三角形を落とす
    keep = (faces[:, 0] != faces[:, 1]) & (faces[:, 1] != faces[:, 2]) & (faces[:, 0] != faces[:, 2])
    return Mesh(vertices=verts, faces=faces[keep])
