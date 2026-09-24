"""ブラウザへ渡す 3D を作る。**部品に切り分けて間引く。**

家具を動かすには部品ごとのメッシュが要る。素材は `mesh_vc.glb`（頂点
カラー付き）と `room.json`（RoomPlan の向き付き境界箱）。切り分けは
`segment.assign_faces` をそのまま使い、色を運ぶために `split_mesh` は
使わず**元の頂点番号を保ったまま**部分集合を取る。

座標は平面図と揃える。world を主方向で回し、原点を図面の左上、Y は床を 0 に
する。こうすると平面図の (x, z) と 3D の (x, z) が同じ枠に乗り、同期が
引き算だけで済む（位置合わせの処理が要らない）。

727,754 面をそのまま送ると base64 で 20MB を超えるので**間引く**。頂点
クラスタリング（格子に丸めて併合）で、部屋は粗く・家具は細かく。位相は
崩れるが見た目は保たれる。実測で 727,754 → 138,001 面 / 3.5MB。
"""
from __future__ import annotations

import base64
import json
import math
import struct
from pathlib import Path

import numpy as np

from . import meshplan, roomplan, segment
from .mesh import Mesh

#: 間引き後の面数の上限。ブラウザへ送る量を決める。
FACE_BUDGET = 170_000
#: 家具の格子（m）。小さいので細かく残す。
OBJECT_CELL = 0.03
#: 部屋の格子の候補。予算に収まる最初のものを使う。
ROOM_CELLS = (0.05, 0.06, 0.07, 0.08, 0.10, 0.14)

FURNITURE_JA = {"sofa": "ソファ", "stairs": "階段", "table": "テーブル",
                "bed": "ベッド", "chair": "椅子", "storage": "収納",
                "television": "テレビ", "refrigerator": "冷蔵庫",
                "oven": "コンロ", "sink": "流し", "toilet": "便器",
                "bathtub": "浴槽", "washerDryer": "洗濯機", "fireplace": "暖炉",
                "stove": "レンジ", "dishwasher": "食洗機"}


def read_glb(path: str | Path) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """頂点カラー付き GLB から位置・色・面を読む。"""
    b = Path(path).read_bytes()
    _, _, total = struct.unpack_from("<III", b, 0)
    off, chunks = 12, {}
    while off < total:
        ln, ty = struct.unpack_from("<II", b, off)
        off += 8
        chunks[ty] = b[off:off + ln]
        off += ln
    g = json.loads(chunks[0x4E4F534A].decode("utf-8"))
    binc = chunks[0x004E4942]

    def acc(i: int, dtype: str, comp: int) -> np.ndarray:
        a = g["accessors"][i]
        bv = g["bufferViews"][a["bufferView"]]
        start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        return np.frombuffer(binc, dtype=dtype, count=a["count"] * comp,
                             offset=start).reshape(-1, comp)

    p = g["meshes"][0]["primitives"][0]
    V = acc(p["attributes"]["POSITION"], "<f4", 3).astype(np.float64)
    C = acc(p["attributes"]["COLOR_0"], "u1", 4)[:, :3]
    F = acc(p["indices"], "<u4", 1).reshape(-1, 3).astype(np.int64)
    return V, C, F


def cluster(V: np.ndarray, C: np.ndarray, F: np.ndarray, cell: float):
    """頂点クラスタリングで間引く。格子に丸めて併合し、潰れた面を捨てる。"""
    key = np.floor(V / cell).astype(np.int64)
    _, inv = np.unique(key, axis=0, return_inverse=True)
    n = int(inv.max()) + 1
    pos = np.zeros((n, 3)); col = np.zeros((n, 3)); cnt = np.zeros(n)
    np.add.at(pos, inv, V)
    np.add.at(col, inv, C.astype(np.float64))
    np.add.at(cnt, inv, 1)
    pos /= cnt[:, None]
    col /= cnt[:, None]
    nf = inv[F]
    keep = (nf[:, 0] != nf[:, 1]) & (nf[:, 1] != nf[:, 2]) & (nf[:, 0] != nf[:, 2])
    nf = nf[keep]
    if len(nf) == 0:
        return pos[:0], col[:0], nf
    used, remap = np.unique(nf, return_inverse=True)
    return pos[used], col[used], remap.reshape(-1, 3)


def _b64(a: np.ndarray) -> str:
    return base64.b64encode(np.ascontiguousarray(a).tobytes()).decode()


def build(bundle: str | Path, face_budget: int = FACE_BUDGET) -> dict:
    """バンドルから部品つきの 3D を組む。`room.json` が無ければ部屋 1 個。"""
    bundle = Path(bundle)
    glb = bundle / "mesh_vc.glb"
    if not glb.exists():
        raise FileNotFoundError("mesh_vc.glb がない（頂点カラーを焼いていない撮影）")
    V, C, F = read_glb(glb)

    room_json = bundle / "room.json"
    if room_json.exists():
        lay = roomplan.load(room_json)
        boxes = segment.boxes_from_room(room_json)
        th = np.array([math.atan2(*(w.p1 - w.p0)[::-1]) for w in lay.walls])
        Lw = np.array([w.length for w in lay.walls])
        ang = float(np.angle(np.sum(Lw * np.exp(4j * th)) / Lw.sum()) / 4)
        floor_y = lay.floor_y
        pts = np.array([p for w in lay.walls for p in (w.p0, w.p1)])
        if lay.floor_polygon is not None:
            pts = np.vstack([pts, lay.floor_polygon])
    else:
        plan = meshplan.extract(Mesh(vertices=V, faces=F))
        if plan is None:
            raise ValueError("平面が取れない")
        lay, boxes = None, []
        ang = math.radians(plan.angle)
        floor_y = plan.floor_y
        pts = plan.outline @ np.linalg.inv(meshplan.rotation(ang)).T

    R = meshplan.rotation(ang)
    rot = pts @ R.T
    x0, z0 = float(rot[:, 0].min()), float(rot[:, 1].min())

    xz = V[:, [0, 2]] @ R.T
    Vl = np.column_stack([xz[:, 0] - x0, V[:, 1] - floor_y, xz[:, 1] - z0])

    if boxes:
        tri = V[F]
        centroids = tri.mean(axis=1)
        normals = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
        normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
        assigned = segment.assign_faces(
            centroids, boxes, floor_y, walls=lay.walls, ceiling_y=lay.ceiling_y,
            normals=normals, adj=segment.face_adjacency(F, V))
    else:
        assigned = np.full(len(F), -1)

    parts, used_faces = [], 0
    for i, b in enumerate(boxes):
        sel = assigned == i
        if sel.sum() < 30:
            continue
        p, c, f = cluster(Vl, C, F[sel], OBJECT_CELL)
        if len(f) == 0:
            continue
        cxz = np.array([b.center[0], b.center[2]]) @ R.T
        # RoomPlan の向き付き境界箱を、3D と同じ枠へ落として渡す。
        #
        # **符号の取り違えを避けるため、向きは JS で組み立てない。** 箱の軸から
        # 隅の座標をここで出し、中心からの相対で渡す。JS 側は中心に置いて
        # dyaw だけ回せばよく、回転の向きを推し量る必要がなくなる。
        corner = []
        for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            w = b.center + b.axes[:, 0] * b.half[0] * sx + b.axes[:, 2] * b.half[2] * sz
            q = np.array([w[0], w[2]]) @ R.T
            corner.append([round(float(q[0] - x0 - (cxz[0] - x0)), 4),
                           round(float(q[1] - z0 - (cxz[1] - z0)), 4)])
        parts.append(dict(
            id=b.identifier, label=FURNITURE_JA.get(b.category, b.category),
            category=b.category, confidence=b.confidence, kind="object",
            c=[round(float(cxz[0] - x0), 4), 0.0, round(float(cxz[1] - z0), 4)],
            box=dict(pts=corner,
                     y0=round(float(b.center[1] - b.half[1] - floor_y), 4),
                     h=round(float(b.half[1] * 2), 4)),
            faces=len(f),
            pos=_b64(p.astype("<f4")), col=_b64(c.round().astype("u1")),
            idx=_b64(f.astype("<u4"))))
        used_faces += len(f)

    room = F[assigned < 0]
    for cell in ROOM_CELLS:
        p, c, f = cluster(Vl, C, room, cell)
        if len(f) + used_faces <= face_budget:
            break
    parts.insert(0, dict(id="__room__", label="部屋", kind="room", faces=len(f),
                         pos=_b64(p.astype("<f4")), col=_b64(c.round().astype("u1")),
                         idx=_b64(f.astype("<u4"))))

    return dict(parts=parts,
                extent=[round(float(rot[:, 0].max() - x0), 3),
                        round(float(rot[:, 1].max() - z0), 3)],
                angle=round(math.degrees(ang), 2),
                rot=[[round(v, 6) for v in row] for row in R.tolist()],
                origin=[round(x0, 4), round(z0, 4)],
                floorY=round(float(floor_y), 4),
                sourceFaces=int(len(F)), roomCell=cell)
