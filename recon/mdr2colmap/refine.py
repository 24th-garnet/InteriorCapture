"""融合メッシュを基準にしたポーズ精密化（frame-to-model ICP）。

**なぜこれが要るか。**
ARKit は frame-to-frame でカメラを追跡するため、誤差が蓄積してドリフトする。
実測では、あるフレームの点群を別フレームに投影したときの深度差に
**系統的な偏りが 8.8mm**（ばらつき 11.5mm と同程度）あった。
偏りはフレームごとに符号が変わるので、ランダムノイズではなくポーズ誤差。

この偏りがある限り、テクスチャの解像度を上げても 3DGS の解像度を上げても
品質は変わらない（実測: アトラス 2048→4096 で PSNR 16.04→16.03、
学習解像度 1920→640 で 23.26→23.26）。書き込む先の位置が合っていないため。

**なぜ ICP で解けるか。**
測った偏りは「投影した深度と実測深度の差」そのもので、これは
point-to-plane ICP が最小化する量に一致する。しかも我々は形状を既に持っている
（LiDAR 融合メッシュ）ので、SfM のように形状とポーズを同時に解く必要がない。
融合メッシュは多数フレームの合意なので、個々のフレームの誤差はそこへ引き戻される。

特徴点マッチングを使わないので、無地の白壁が多い内装でも成立する。
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .colmap import arkit_c2w_to_opencv_c2w
from .mdr import Bundle, Frame
from .mesh import Mesh
from .pointcloud import PIXEL_CENTER_OFFSET


@dataclass
class RefineStats:
    frame_index: int
    used_points: int
    #: 補正前後の point-to-plane 残差の中央値（メートル）
    before: float
    after: float
    #: 補正量
    translation: float
    rotation_deg: float


def _skew(v: np.ndarray) -> np.ndarray:
    return np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])


def _frame_points(bundle: Bundle, frame: Frame, conf_min: int,
                  max_points: int, depth_range: tuple[float, float],
                  rng: np.random.Generator) -> np.ndarray:
    """フレームの深度を OpenCV カメラ座標の点群にする（world 変換は呼び出し側）。"""
    depth = bundle.depth(frame.index)
    conf = bundle.confidence(frame.index)
    dh, dw = depth.shape
    near, far = depth_range
    mask = (conf >= conf_min) & np.isfinite(depth) & (depth > near) & (depth < far)
    if not mask.any():
        return np.zeros((0, 3))

    vs, us = np.nonzero(mask)
    if len(vs) > max_points:
        sel = rng.choice(len(vs), max_points, replace=False)
        vs, us = vs[sel], us[sel]

    z = depth[vs, us].astype(np.float64)
    k = frame.intrinsics.scaled_to(bundle.manifest.video_wh, (dw, dh))
    x = (us + PIXEL_CENTER_OFFSET - k.cx) * z / k.fx
    y = (vs + PIXEL_CENTER_OFFSET - k.cy) * z / k.fy
    return np.stack([x, y, z], axis=1)


def refine_frame(
    cam_points: np.ndarray,
    c2w_arkit: np.ndarray,
    tree,
    centroids: np.ndarray,
    normals: np.ndarray,
    iterations: int = 6,
    max_correspondence: float = 0.06,
) -> tuple[np.ndarray, float, float]:
    """1 フレームのポーズを point-to-plane ICP で補正する。

    戻り値は (補正後の c2w_arkit, 補正前残差, 補正後残差)。

    微小回転 ω と平行移動 t について、各対応の誤差を
        e = n · ((p + ω×p + t) - q)
    と線形化し、6 元の最小二乗で解く。point-to-point より収束が速く、
    平面が支配的な室内では特に効く。
    """
    pose = c2w_arkit.copy()
    first_residual = None

    for _ in range(iterations):
        c2w_cv = arkit_c2w_to_opencv_c2w(pose)
        world = cam_points @ c2w_cv[:3, :3].T + c2w_cv[:3, 3]

        dist, idx = tree.query(world, k=1)
        keep = dist < max_correspondence
        if keep.sum() < 50:
            break

        p = world[keep]
        q = centroids[idx[keep]]
        n = normals[idx[keep]]

        residual = np.abs(np.sum((p - q) * n, axis=1))
        if first_residual is None:
            first_residual = float(np.median(residual))

        # A x = b,  x = [ω(3), t(3)]
        A = np.concatenate([np.cross(p, n), n], axis=1)
        b = -np.sum((p - q) * n, axis=1)

        # 対応距離で重み付けして外れ値の影響を抑える
        w = 1.0 / (1.0 + (dist[keep] / (max_correspondence * 0.5)) ** 2)
        Aw = A * w[:, None]
        try:
            x, *_ = np.linalg.lstsq(Aw.T @ A, Aw.T @ b, rcond=None)
        except np.linalg.LinAlgError:
            break

        omega, t = x[:3], x[3:]
        angle = np.linalg.norm(omega)
        if angle < 1e-9:
            R = np.eye(3)
        else:
            axis = omega / angle
            K = _skew(axis)
            R = np.eye(3) + np.sin(angle) * K + (1 - np.cos(angle)) * (K @ K)

        delta = np.eye(4)
        delta[:3, :3] = R
        delta[:3, 3] = t
        # world 側の補正なので左から掛ける。ARKit 規約に戻すため FLIP を挟む。
        c2w_cv = delta @ c2w_cv
        pose = arkit_c2w_to_opencv_c2w(c2w_cv)   # FLIP は自己逆行列なので往復で戻る

        if angle < 1e-5 and np.linalg.norm(t) < 1e-5:
            break

    # 最終残差
    c2w_cv = arkit_c2w_to_opencv_c2w(pose)
    world = cam_points @ c2w_cv[:3, :3].T + c2w_cv[:3, 3]
    dist, idx = tree.query(world, k=1)
    keep = dist < max_correspondence
    last = float(np.median(np.abs(np.sum((world[keep] - centroids[idx[keep]]) * normals[idx[keep]], axis=1)))) if keep.any() else np.inf
    return pose, (first_residual if first_residual is not None else np.inf), last


def refine(
    bundle: Bundle,
    mesh: Mesh,
    conf_min: int = 2,
    max_points: int = 4000,
    iterations: int = 6,
    depth_range: tuple[float, float] = (0.2, 4.0),
    progress=None,
) -> tuple[list[np.ndarray], list[RefineStats]]:
    """全フレームのポーズを補正する。戻り値は (補正後 c2w のリスト, 統計)。"""
    from scipy.spatial import cKDTree

    centroids = mesh.face_centroids
    normals = mesh.face_normals
    tree = cKDTree(centroids)
    rng = np.random.default_rng(0)

    poses: list[np.ndarray] = []
    stats: list[RefineStats] = []
    for n, f in enumerate(bundle.frames):
        pts = _frame_points(bundle, f, conf_min, max_points, depth_range, rng)
        if len(pts) < 50:
            poses.append(f.c2w_arkit.copy())
            continue
        new_pose, before, after = refine_frame(
            pts, f.c2w_arkit, tree, centroids, normals, iterations)
        poses.append(new_pose)
        d = new_pose[:3, 3] - f.c2w_arkit[:3, 3]
        R = f.c2w_arkit[:3, :3].T @ new_pose[:3, :3]
        ang = np.degrees(np.arccos(np.clip((np.trace(R) - 1) / 2, -1, 1)))
        stats.append(RefineStats(f.index, len(pts), before, after,
                                 float(np.linalg.norm(d)), float(ang)))
        if progress:
            progress(n + 1, len(bundle.frames))
    return poses, stats
