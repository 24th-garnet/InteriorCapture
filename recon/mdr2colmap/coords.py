"""ARKit と OpenCV の座標系を橋渡しする。

ARKit は X 右 / Y 上 / Z 後 でカメラ→world、OpenCV は X 右 / Y 下 / Z 前 で
world→カメラ。`FLIP` をカメラ側（右から）に掛けるので、**world 座標系は
ARKit のまま変わらない**。

パイプライン全体で最もバグりやすい箇所なので、変換規約をここに集約する。
capture(iPadOS) 側では一切変換を行わない。

テクスチャ焼き込み（`texture.py`）と再投影の検証（`verify.py`）が使う。

もとは 3DGS 学習器へ COLMAP 形式を書き出すためのモジュール（`colmap.py`）
だったが、**3DGS を採用しない方針になった**ため座標変換だけを残した。
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from .mdr import Frame, Intrinsics

#: ARKit のカメラ軸を OpenCV のカメラ軸に合わせる。対角行列なので自身が逆行列。
FLIP = np.diag([1.0, -1.0, -1.0, 1.0])


def arkit_c2w_to_opencv_c2w(c2w_arkit: np.ndarray) -> np.ndarray:
    """ARKit の camera->world を OpenCV 規約の camera->world にする。"""
    return c2w_arkit @ FLIP


def arkit_c2w_to_world2cam(c2w_arkit: np.ndarray) -> np.ndarray:
    """ARKit の camera->world から COLMAP が要求する world->camera を得る。"""
    return np.linalg.inv(arkit_c2w_to_opencv_c2w(c2w_arkit))


def rotmat_to_qvec(R: np.ndarray) -> np.ndarray:
    """回転行列 → クォータニオン (qw, qx, qy, qz)。

    COLMAP の images.txt は QW QX QY QZ の順。
    trace ベースの素朴な実装は trace が負のとき数値的に不安定なので、
    最大成分で場合分けする定番の方法を使う。
    """
    m = np.asarray(R, dtype=np.float64)
    t = np.trace(m)
    if t > 0.0:
        s = np.sqrt(t + 1.0) * 2.0
        qw = 0.25 * s
        qx = (m[2, 1] - m[1, 2]) / s
        qy = (m[0, 2] - m[2, 0]) / s
        qz = (m[1, 0] - m[0, 1]) / s
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2.0
        qw = (m[2, 1] - m[1, 2]) / s
        qx = 0.25 * s
        qy = (m[0, 1] + m[1, 0]) / s
        qz = (m[0, 2] + m[2, 0]) / s
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2.0
        qw = (m[0, 2] - m[2, 0]) / s
        qx = (m[0, 1] + m[1, 0]) / s
        qy = 0.25 * s
        qz = (m[1, 2] + m[2, 1]) / s
    else:
        s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2.0
        qw = (m[1, 0] - m[0, 1]) / s
        qx = (m[0, 2] + m[2, 0]) / s
        qy = (m[1, 2] + m[2, 1]) / s
        qz = 0.25 * s

    q = np.array([qw, qx, qy, qz], dtype=np.float64)
    n = np.linalg.norm(q)
    if n == 0.0:
        raise ValueError("回転行列からクォータニオンを作れませんでした")
    q /= n
    # 符号の一意化（-q と q は同じ回転）。差分を見るときに安定する。
    if q[0] < 0.0:
        q = -q
    return q


def qvec_to_rotmat(q: np.ndarray) -> np.ndarray:
    """rotmat_to_qvec の逆。テストと検証に使う。"""
    w, x, y, z = np.asarray(q, dtype=np.float64)
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
            [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
            [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
        ],
        dtype=np.float64,
    )


def project(points_world: np.ndarray, c2w_arkit: np.ndarray, K: Intrinsics) -> tuple[np.ndarray, np.ndarray]:
    """ARKit world 座標の点群を画像に投影する。

    戻り値は (uv, depth)。depth <= 0 の点はカメラ背面にある。
    """
    w2c = arkit_c2w_to_world2cam(c2w_arkit)
    pts = np.asarray(points_world, dtype=np.float64)
    cam = pts @ w2c[:3, :3].T + w2c[:3, 3]
    z = cam[:, 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        u = K.fx * cam[:, 0] / z + K.cx
        v = K.fy * cam[:, 1] / z + K.cy
    return np.stack([u, v], axis=1), z


# -- 書き出し ----------------------------------------------------------------


#: COLMAP のカメラモデル ID。PINHOLE のパラメータは fx, fy, cx, cy。
