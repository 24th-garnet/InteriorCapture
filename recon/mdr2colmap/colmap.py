"""ARKit → COLMAP の座標変換と COLMAP text model の書き出し。

パイプライン全体で最もバグりやすい箇所なので、変換規約をここに集約する。
capture(iPadOS) 側では一切変換を行わない。

座標系:
  ARKit          右手系、X 右 / Y 上 / Z 後（カメラは -Z を向く）
                 camera.transform は camera->world
  COLMAP/OpenCV  右手系、X 右 / Y 下 / Z 前（RIGHT_DOWN_FRONT）
                 images.txt は world->camera

したがって「カメラ軸の Y と Z を反転」して「逆行列を取る」の 2 段階になる。
FLIP はカメラ側（右から）に掛けるので、**world 座標系は ARKit のまま変わらない**。
点群も ARKit world 座標のまま書けばよい。
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
MODEL_PINHOLE = 1


def write_cameras_bin(path: Path, frames: list[Frame], width: int, height: int) -> None:
    """cameras.bin。1 フレーム = 1 カメラで書く。

    ARKit は intrinsics を毎フレーム再計算するため、セッション共通の 1 カメラに
    まとめると再投影誤差になる。COLMAP はカメラを画像間で共有しなくても構わない。

    モデルは PINHOLE。ARKit は非線形レンズ歪みを既に補正済みで（歪みルックアップ
    テーブルは AVCameraCalibrationData にはあるが ARKit では非公開）、
    渡される画像は歪み補正後の座標系にある。

    レイアウト: uint64 件数 / 各件 [uint32 id, uint32 model, uint64 W, uint64 H, double params...]
    """
    with path.open("wb") as fh:
        fh.write(np.uint64(len(frames)).tobytes())
        for cam_id, f in enumerate(frames, start=1):
            k = f.intrinsics
            fh.write(np.uint32(cam_id).tobytes())
            fh.write(np.uint32(MODEL_PINHOLE).tobytes())
            fh.write(np.uint64(width).tobytes())
            fh.write(np.uint64(height).tobytes())
            fh.write(np.array([k.fx, k.fy, k.cx, k.cy], dtype="<f8").tobytes())


def write_images_bin(path: Path, frames: list[Frame], names: list[str]) -> None:
    """images.bin。

    レイアウト: uint64 件数 / 各件 [uint32 image_id, double[4] qvec(w,x,y,z),
    double[3] tvec, uint32 camera_id, NUL 終端の名前, uint64 2D点数]

    2D 点は 3DGS の初期化に不要なので 0 件で書く。
    """
    with path.open("wb") as fh:
        fh.write(np.uint64(len(frames)).tobytes())
        for i, (f, name) in enumerate(zip(frames, names), start=1):
            w2c = arkit_c2w_to_world2cam(f.c2w_arkit)
            q = rotmat_to_qvec(w2c[:3, :3])
            t = w2c[:3, 3]
            fh.write(np.uint32(i).tobytes())
            fh.write(np.asarray(q, dtype="<f8").tobytes())
            fh.write(np.asarray(t, dtype="<f8").tobytes())
            fh.write(np.uint32(i).tobytes())  # camera_id = image_id
            fh.write(name.encode("utf-8") + b"\x00")
            fh.write(np.uint64(0).tobytes())  # POINTS2D は 0 件


def write_points3d_ply(path: Path, xyz: np.ndarray, rgb: np.ndarray) -> None:
    """初期点群を binary PLY で書く。

    points3D.bin はトラック情報が可変長で書くのが面倒だが、COLMAP ローダは
    points3D.bin が無ければ points3D.ply にフォールバックする。
    こちらの方が単純で、他ツールでも開ける。

    座標は ARKit world 系のまま。FLIP はカメラ側にしか掛けていないので world は不変。
    """
    n = len(xyz)
    header = (
        "ply\n"
        "format binary_little_endian 1.0\n"
        f"element vertex {n}\n"
        "property float x\nproperty float y\nproperty float z\n"
        "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        "end_header\n"
    )
    verts = np.empty(
        n,
        dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4"),
               ("red", "u1"), ("green", "u1"), ("blue", "u1")],
    )
    p = np.asarray(xyz, dtype=np.float32)
    c = np.asarray(rgb, dtype=np.uint8)
    verts["x"], verts["y"], verts["z"] = p[:, 0], p[:, 1], p[:, 2]
    verts["red"], verts["green"], verts["blue"] = c[:, 0], c[:, 1], c[:, 2]

    with path.open("wb") as fh:
        fh.write(header.encode("ascii"))
        fh.write(verts.tobytes())
