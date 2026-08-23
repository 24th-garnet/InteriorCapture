"""LiDAR 深度から初期点群を作る。

3DGS の初期化に SfM の疎な点（数千〜数万）ではなく LiDAR 由来の密な点（50〜200 万）を
使えることが、このパイプラインの速度と品質の要。densification の回数が減り、
無地の壁でも初期形状が与えられる。

ここで作るのは「初期化用の点群」であって depth supervision ではない。
depth loss は学習器側の改造が必要なので Phase 3 で扱う。
"""

from __future__ import annotations

import numpy as np
from PIL import Image

from .colmap import arkit_c2w_to_opencv_c2w
from .mdr import Bundle, Frame

#: 連続画素座標は「配列インデックス + 0.5」で扱う（COLMAP と同じ規約）。
PIXEL_CENTER_OFFSET = 0.5


def unproject_frame(
    bundle: Bundle,
    frame: Frame,
    conf_min: int,
    depth_range: tuple[float, float] = (0.1, 5.0),
    with_color: bool = True,
) -> tuple[np.ndarray, np.ndarray]:
    """1 フレームの深度を ARKit world 座標の点群にする。

    戻り値は (xyz (N,3) float32, rgb (N,3) uint8)。
    """
    depth = bundle.depth(frame.index)
    conf = bundle.confidence(frame.index)
    dh, dw = depth.shape

    near, far = depth_range
    mask = (conf >= conf_min) & np.isfinite(depth) & (depth > near) & (depth < far)
    if not mask.any():
        return np.zeros((0, 3), np.float32), np.zeros((0, 3), np.uint8)

    vs, us = np.nonzero(mask)
    z = depth[vs, us].astype(np.float64)

    # 深度マップは RGB と同一 FOV なので内部パラメータは単純スケールで得られる
    kd = frame.intrinsics.scaled_to(bundle.manifest.video_wh, (dw, dh))
    x = (us + PIXEL_CENTER_OFFSET - kd.cx) * z / kd.fx
    y = (vs + PIXEL_CENTER_OFFSET - kd.cy) * z / kd.fy

    # 深度の非投影は OpenCV 規約のカメラ座標（X 右 / Y 下 / Z 前）で自然に成立する
    cam = np.stack([x, y, z], axis=1)
    c2w = arkit_c2w_to_opencv_c2w(frame.c2w_arkit)
    world = cam @ c2w[:3, :3].T + c2w[:3, 3]

    if not with_color:
        return world.astype(np.float32), np.full((len(world), 3), 128, np.uint8)

    rgb = _sample_color(bundle, frame, us, vs, (dw, dh))
    return world.astype(np.float32), rgb


def _sample_color(
    bundle: Bundle, frame: Frame, us: np.ndarray, vs: np.ndarray, depth_wh: tuple[int, int]
) -> np.ndarray:
    """深度画素に対応する RGB を最近傍でサンプルする。"""
    img = np.asarray(Image.open(bundle.image_path(frame.index)).convert("RGB"))
    ih, iw = img.shape[:2]
    dw, dh = depth_wh
    ix = np.clip(((us + PIXEL_CENTER_OFFSET) * iw / dw).astype(np.int64), 0, iw - 1)
    iy = np.clip(((vs + PIXEL_CENTER_OFFSET) * ih / dh).astype(np.int64), 0, ih - 1)
    return img[iy, ix]


def voxel_downsample(
    xyz: np.ndarray, rgb: np.ndarray, voxel: float
) -> tuple[np.ndarray, np.ndarray]:
    """ボクセル平均でダウンサンプルする。

    座標を整数キーに畳んでから 1 次元に詰め、bincount で平均を取る。
    np.unique(axis=0) より桁違いに速い。
    """
    if len(xyz) == 0 or voxel <= 0:
        return xyz, rgb

    keys = np.floor(xyz.astype(np.float64) / voxel).astype(np.int64)
    keys -= keys.min(axis=0)
    dims = keys.max(axis=0) + 1
    if np.prod(dims.astype(object)) > np.iinfo(np.int64).max:
        raise ValueError("ボクセルグリッドが大きすぎます。voxel を大きくしてください。")

    flat = keys[:, 0] + dims[0] * (keys[:, 1] + dims[1] * keys[:, 2])
    _, inverse, counts = np.unique(flat, return_inverse=True, return_counts=True)

    n = len(counts)
    out_xyz = np.zeros((n, 3), np.float64)
    out_rgb = np.zeros((n, 3), np.float64)
    for c in range(3):
        out_xyz[:, c] = np.bincount(inverse, weights=xyz[:, c], minlength=n) / counts
        out_rgb[:, c] = np.bincount(inverse, weights=rgb[:, c], minlength=n) / counts

    return out_xyz.astype(np.float32), np.clip(out_rgb, 0, 255).astype(np.uint8)


def remove_statistical_outliers(
    xyz: np.ndarray, rgb: np.ndarray, k: int = 8, sigma: float = 2.0
) -> tuple[np.ndarray, np.ndarray]:
    """近傍距離の平均が全体分布から外れる点を落とす。

    LiDAR の縁で飛ぶ点（深度の不連続をまたいだ画素）が floater の温床になるので、
    初期点群の段階で削っておく。
    """
    from scipy.spatial import cKDTree

    if len(xyz) <= k:
        return xyz, rgb

    tree = cKDTree(xyz)
    dists, _ = tree.query(xyz, k=k + 1)  # 自分自身を含むので k+1
    mean_d = dists[:, 1:].mean(axis=1)
    thresh = mean_d.mean() + sigma * mean_d.std()
    keep = mean_d <= thresh
    return xyz[keep], rgb[keep]


def build(
    bundle: Bundle,
    frames: list[Frame],
    conf_min: int,
    voxel: float = 0.02,
    depth_range: tuple[float, float] = (0.1, 5.0),
    denoise: bool = True,
    progress=None,
) -> tuple[np.ndarray, np.ndarray]:
    """全フレームから統合点群を作る。

    フレームごとに非投影してから貯め、最後にまとめてダウンサンプルする。
    """
    chunks_xyz: list[np.ndarray] = []
    chunks_rgb: list[np.ndarray] = []

    for n, f in enumerate(frames, start=1):
        p, c = unproject_frame(bundle, f, conf_min, depth_range)
        if len(p):
            chunks_xyz.append(p)
            chunks_rgb.append(c)
        if progress:
            progress(n, len(frames))

    if not chunks_xyz:
        return np.zeros((0, 3), np.float32), np.zeros((0, 3), np.uint8)

    xyz = np.concatenate(chunks_xyz)
    rgb = np.concatenate(chunks_rgb)

    xyz, rgb = voxel_downsample(xyz, rgb, voxel)
    if denoise:
        xyz, rgb = remove_statistical_outliers(xyz, rgb)
    return xyz, rgb


def build_with_normals(
    bundle: Bundle,
    mesh,
    frames: list[Frame],
    conf_min: int,
    voxel: float = 0.02,
    depth_range: tuple[float, float] = (0.1, 5.0),
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """点群に加えて、各点の法線をメッシュから拾う。

    法線は 3DGS を「面に貼り付いた薄い楕円」で初期化するために使う。
    深度の非投影だけでは法線が得られない（近傍から推定はできるがノイズが乗る）ので、
    ARKit が出した面の法線を最近傍探索で引き当てる。
    """
    from scipy.spatial import cKDTree

    xyz, rgb = build(bundle, frames, conf_min, voxel, depth_range, denoise=True)
    if not len(xyz):
        return xyz, rgb, np.zeros((0, 3), np.float32)

    centroids = mesh.face_centroids
    normals = mesh.face_normals
    tree = cKDTree(centroids)
    _, idx = tree.query(xyz, k=1)
    return xyz, rgb, normals[idx].astype(np.float32)
