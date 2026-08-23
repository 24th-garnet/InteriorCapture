"""ARMeshAnchor 由来のメッシュ (mesh.ply) の読み込みと幾何解析。

3DGS の学習には使わない。間取り・寸法・dollhouse という Tier 1 の用途に使う。
座標系は ARKit world のまま（右手系、X 右 / Y 上 / Z 後、重力整合）。
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

import numpy as np


@dataclass
class Mesh:
    #: (N, 3) 頂点。ARKit world 座標、Y が重力上向き。
    vertices: np.ndarray
    #: (M, 3) 三角形の頂点インデックス。
    faces: np.ndarray

    @property
    def triangles(self) -> np.ndarray:
        return self.vertices[self.faces]

    @property
    def face_normals(self) -> np.ndarray:
        """正規化した面法線。縮退三角形は零ベクトルになる。"""
        t = self.triangles
        n = np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0])
        return n / np.maximum(np.linalg.norm(n, axis=1), 1e-12)[:, None]

    @property
    def face_areas(self) -> np.ndarray:
        t = self.triangles
        return 0.5 * np.linalg.norm(np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0]), axis=1)

    @property
    def face_centroids(self) -> np.ndarray:
        return self.triangles.mean(axis=1)

    def vertical_faces(self, max_up: float = 0.25) -> np.ndarray:
        """壁とみなせる面のマスク。法線の鉛直成分が小さいもの。"""
        return np.abs(self.face_normals[:, 1]) < max_up

    def horizontal_faces(self, min_up: float = 0.9) -> np.ndarray:
        """床・天井とみなせる面のマスク。"""
        return np.abs(self.face_normals[:, 1]) > min_up


def read_ply_mesh(path: str | Path) -> Mesh:
    """binary_little_endian の PLY を読む。

    capture 側が書く形式（float x/y/z の頂点 + uchar-int3 の面）だけを想定する。
    汎用 PLY パーサではない。
    """
    path = Path(path)
    with path.open("rb") as fh:
        header = b""
        while b"end_header" not in header:
            line = fh.readline()
            if not line:
                raise ValueError(f"PLY ヘッダが終わらないまま EOF: {path}")
            header += line

        text = header.decode("ascii", "replace")
        if "binary_little_endian" not in text:
            raise ValueError(f"binary_little_endian の PLY のみ対応しています: {path}")

        m_v = re.search(r"element vertex (\d+)", text)
        m_f = re.search(r"element face (\d+)", text)
        if not m_v:
            raise ValueError(f"element vertex が見つかりません: {path}")
        n_v = int(m_v.group(1))
        n_f = int(m_f.group(1)) if m_f else 0

        verts = np.frombuffer(fh.read(n_v * 12), dtype="<f4", count=n_v * 3)
        verts = verts.reshape(n_v, 3).astype(np.float64)

        faces = np.zeros((0, 3), np.int64)
        if n_f:
            rec = np.dtype([("count", "u1"), ("idx", "<i4", 3)])
            faces = np.frombuffer(fh.read(n_f * rec.itemsize), dtype=rec, count=n_f)
            faces = faces["idx"].astype(np.int64)

    return Mesh(vertices=verts, faces=faces)
