"""RoomPlan の物体境界箱で 3D モデルを家具ごとに切り分ける。

**目的は「平面図で家具を動かすと 3D 側も動く」を成立させること。**
現在の 3D モデルは融合済みの 1 枚のメッシュ／1 群のガウシアンで、家具が
個体になっていない。動かすには先に分ける必要がある。

RoomPlan は家具を `transform`（列優先 4x4）と `dimensions` を持つ
**向き付き境界箱**として返す。箱の中に入る面／ガウシアンを選べば分離できる。

実測（`room-33d49373`、148,897 面）::

    収納    0.86×2.11×0.35   14,260 面 (9.6%)   高さ -1.64〜+0.53
    テーブル 1.29×0.78×0.58    7,957 面 (5.3%)   高さ -1.64〜-0.85
    椅子    0.54×1.14×0.64    2,932 面 (2.0%)   高さ -1.63〜-0.49
    ベッド   1.49×0.52×2.13    6,205 面 (4.2%)   高さ -1.64〜-1.12

    家具に 19.9% / 壁・床・天井に 80.1%

**高さ範囲がすべて床から始まる。** 箱が正しい位置にある証拠だが、同時に
**床面を巻き込む**ことも意味する。椅子を動かすと床の一部が付いてくるので、
床から `FLOOR_MARGIN` 以内の面は部屋側に残す。

既知の限界
---------
- **動かした跡に穴が空く。** 家具の裏側は撮影されていないので、動かすと
  未再構成の空間が露出する。床の補完は別課題。
- 面は重心で振り分けるため、箱の境界をまたぐ面で縁がぎざつく。
- メッシュは位相を切るので縁が荒れやすい。**3DGS のほうが有利**で、
  箱内のガウシアンを選んで動かすだけで済む。
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .mesh import Mesh

#: 床からこの高さ以内の面・点は家具に含めず部屋側に残す。
#:
#: RoomPlan の箱は床面から始まるので、そのまま切ると家具が床を巻き込む。
#: 4cm は「家具の脚の接地部は残す」程度の妥協。大きくすると脚が消え、
#: 小さくすると床が付いてくる。
FLOOR_MARGIN = 0.04
#: 箱をわずかに膨らませる。境界ぴったりだと家具の縁が欠ける。
BOX_INFLATE = 1.04


@dataclass
class Box:
    """向き付き境界箱。"""

    identifier: str
    category: str
    center: np.ndarray          #: world 座標の中心 (3,)
    axes: np.ndarray            #: 各軸の単位ベクトルを列に持つ (3,3)
    half: np.ndarray            #: 各軸方向の半径 (3,)

    def contains(self, points: np.ndarray, inflate: float = BOX_INFLATE) -> np.ndarray:
        """点群が箱の中にあるかを返す。"""
        local = (points - self.center) @ self.axes
        return np.all(np.abs(local) <= self.half * inflate, axis=1)

    @property
    def floor_y(self) -> float:
        """箱の下端の高さ。"""
        return float(self.center[1] - self.half[1])


def boxes_from_room(room_json: str | Path) -> list[Box]:
    """`room.json` の objects を境界箱にする。"""
    import json

    data = json.loads(Path(room_json).read_text())
    out: list[Box] = []
    for o in data.get("objects", []):
        T = np.array(o["transform"], float).reshape(4, 4).T
        axes = T[:3, :3]
        # 各軸を単位化する。RoomPlan は回転行列だが念のため正規化する。
        norms = np.linalg.norm(axes, axis=0)
        norms[norms < 1e-9] = 1.0
        cat = o.get("category")
        out.append(Box(
            identifier=str(o["identifier"]),
            category=next(iter(cat), "unknown") if isinstance(cat, dict) else str(cat),
            center=T[:3, 3].copy(),
            axes=axes / norms,
            half=np.array(o["dimensions"], float) / 2,
        ))
    return out


@dataclass
class SplitMesh:
    """切り分けた結果。`remainder` が部屋（壁・床・天井）。"""

    remainder: Mesh
    parts: dict[str, Mesh]
    #: 各家具に割り当てた面数。振り分けが妥当かの確認用。
    counts: dict[str, int]
    #: 床付近で除外した面数。
    floor_excluded: int


def split_mesh(mesh: Mesh, boxes: list[Box], floor_y: float,
               floor_margin: float = FLOOR_MARGIN) -> SplitMesh:
    """メッシュを家具ごとに切り分ける。

    面は**重心**で振り分ける。頂点単位で判定すると 1 つの面が複数の
    部品にまたがり、どちらに入れるかが決まらない。
    """
    V, F = mesh.vertices, mesh.faces
    centroids = V[F].mean(axis=1)

    # 床付近は家具に含めない
    near_floor = centroids[:, 1] < floor_y + floor_margin

    assigned = np.full(len(F), -1, dtype=np.int32)
    for i, b in enumerate(boxes):
        inside = b.contains(centroids) & ~near_floor & (assigned < 0)
        assigned[inside] = i

    parts: dict[str, Mesh] = {}
    counts: dict[str, int] = {}
    for i, b in enumerate(boxes):
        sel = assigned == i
        counts[b.identifier] = int(sel.sum())
        if sel.any():
            parts[b.identifier] = _subset(V, F[sel])

    remainder = _subset(V, F[assigned < 0])
    excluded = int((near_floor & (assigned < 0)).sum())
    return SplitMesh(remainder=remainder, parts=parts, counts=counts,
                     floor_excluded=excluded)


def _subset(vertices: np.ndarray, faces: np.ndarray) -> Mesh:
    """使われている頂点だけを残してインデックスを詰め直す。"""
    if len(faces) == 0:
        return Mesh(vertices=np.zeros((0, 3), np.float32), faces=np.zeros((0, 3), np.int64))
    used = np.unique(faces)
    remap = np.full(int(used.max()) + 1, -1, dtype=np.int64)
    remap[used] = np.arange(len(used))
    return Mesh(vertices=vertices[used].copy(), faces=remap[faces])


# --- 移動の適用 -------------------------------------------------------------


def move_matrix(box: Box, dx: float, dz: float, dyaw_deg: float) -> np.ndarray:
    """家具を動かす 4x4 行列。

    **回転は家具自身の中心まわり。** world 原点まわりに回すと家具が
    部屋の外へ飛ぶ。平面図の編集器も中心まわりで回している。

    Y 軸（上）まわりの回転のみ。家具を傾ける操作は用途上ない。
    """
    a = np.radians(dyaw_deg)
    ca, sa = np.cos(a), np.sin(a)
    R = np.array([[ca, 0.0, sa], [0.0, 1.0, 0.0], [-sa, 0.0, ca]])
    c = box.center.copy()
    c[1] = 0.0                      # 高さは動かさない（床に置いたまま）

    M = np.eye(4)
    M[:3, :3] = R
    # 中心へ移す → 回す → 戻す → 平行移動
    M[:3, 3] = c - R @ c + np.array([dx, 0.0, dz])
    return M


def apply_move(mesh: Mesh, M: np.ndarray) -> Mesh:
    v = mesh.vertices @ M[:3, :3].T + M[:3, 3]
    return Mesh(vertices=v.astype(np.float32), faces=mesh.faces)


# --- 3DGS（splat）------------------------------------------------------------


def split_splats(xyz: np.ndarray, boxes: list[Box], floor_y: float,
                 floor_margin: float = FLOOR_MARGIN) -> tuple[np.ndarray, dict[str, np.ndarray]]:
    """ガウシアンの位置から所属を決める。戻り値は (部屋のマスク, {id: マスク})。

    メッシュより素直。位相を切る必要がなく、点を選ぶだけで済む。
    縁のぎざつきも起きない。
    """
    near_floor = xyz[:, 1] < floor_y + floor_margin
    assigned = np.full(len(xyz), -1, dtype=np.int32)
    for i, b in enumerate(boxes):
        inside = b.contains(xyz) & ~near_floor & (assigned < 0)
        assigned[inside] = i
    masks = {b.identifier: (assigned == i) for i, b in enumerate(boxes)}
    return assigned < 0, masks


# --- 書き出し ---------------------------------------------------------------


def write_ply_mesh(path: str | Path, mesh: Mesh) -> None:
    """binary PLY で書く。読み側は `read_ply_mesh`。

    面のインデックスは PLY の慣習どおり uchar の個数 + int32 の並びで書く。
    """
    v = np.asarray(mesh.vertices, np.float32)
    f = np.asarray(mesh.faces, np.int32)
    header = (
        "ply\nformat binary_little_endian 1.0\n"
        f"element vertex {len(v)}\n"
        "property float x\nproperty float y\nproperty float z\n"
        f"element face {len(f)}\n"
        "property list uchar int vertex_indices\n"
        "end_header\n"
    )
    face_dtype = np.dtype([("n", "u1"), ("i", "<i4", 3)])
    fa = np.empty(len(f), face_dtype)
    fa["n"] = 3
    fa["i"] = f
    with Path(path).open("wb") as fh:
        fh.write(header.encode("ascii"))
        fh.write(v.tobytes())
        fh.write(fa.tobytes())


@dataclass
class Move:
    """家具 1 個の移動。平面図の編集器が書き出す形。"""

    identifier: str
    dx: float = 0.0
    dz: float = 0.0
    dyaw: float = 0.0


def load_moves(path: str | Path) -> list[Move]:
    """編集器の JSON を読む。`moved` 配列の `delta` を使う。"""
    import json

    data = json.loads(Path(path).read_text())
    out = []
    for m in data.get("moved", []):
        d = m.get("delta", {})
        out.append(Move(
            identifier=str(m["id"]),
            dx=float(d.get("dx", 0.0)),
            dz=float(d.get("dz", 0.0)),
            dyaw=float(d.get("dyaw", 0.0)),
        ))
    return out


def arrange_mesh(mesh: Mesh, boxes: list[Box], floor_y: float,
                 moves: list[Move]) -> Mesh:
    """家具を動かした 1 枚のメッシュを返す。

    **編集器の識別子は先頭 8 桁に切っている**ので、前方一致で照合する。
    完全一致だけを見ると黙って何も動かない結果になる。
    """
    split = split_mesh(mesh, boxes, floor_y)
    by_move = {m.identifier: m for m in moves}

    verts = [split.remainder.vertices]
    faces = [split.remainder.faces]
    offset = len(split.remainder.vertices)

    for b in boxes:
        part = split.parts.get(b.identifier)
        if part is None or len(part.faces) == 0:
            continue
        mv = by_move.get(b.identifier)
        if mv is None:
            mv = next((m for m in moves if b.identifier.startswith(m.identifier)), None)
        if mv is not None and (mv.dx or mv.dz or mv.dyaw):
            part = apply_move(part, move_matrix(b, mv.dx, mv.dz, mv.dyaw))
        verts.append(part.vertices)
        faces.append(part.faces + offset)
        offset += len(part.vertices)

    return Mesh(vertices=np.concatenate(verts).astype(np.float32),
                faces=np.concatenate(faces).astype(np.int64))


# --- splat の入出力 ---------------------------------------------------------
#
# Brush が吐く PLY はプロパティが 59 個ある（位置 3 / スケール 3 / 不透明度 1 /
# 回転 4 / SH 48）。**列を解釈せずそのまま持ち回る**のが安全で、
# 位置と回転だけ触って残りは触らない。


@dataclass
class SplatCloud:
    """プロパティ名と生の構造化配列を保つ。"""

    names: list[str]
    data: np.ndarray            #: 構造化配列（1 行 = 1 ガウシアン）
    header_comments: list[str]

    @property
    def xyz(self) -> np.ndarray:
        return np.stack([self.data["x"], self.data["y"], self.data["z"]], axis=1).astype(np.float64)

    def __len__(self) -> int:
        return len(self.data)


def read_splat_ply(path: str | Path) -> SplatCloud:
    names: list[str] = []
    comments: list[str] = []
    count = 0
    types = {"float": "<f4", "double": "<f8", "uchar": "u1", "int": "<i4"}
    fields: list[tuple[str, str]] = []
    with Path(path).open("rb") as fh:
        line = fh.readline().decode("ascii").strip()
        if line != "ply":
            raise ValueError(f"PLY ではありません: {path}")
        while True:
            line = fh.readline().decode("ascii", "replace").strip()
            if line.startswith("comment"):
                comments.append(line[len("comment "):])
            elif line.startswith("element vertex"):
                count = int(line.split()[-1])
            elif line.startswith("property"):
                _, typ, name = line.split()
                names.append(name)
                fields.append((name, types[typ]))
            elif line == "end_header":
                break
        dtype = np.dtype(fields)
        raw = fh.read(count * dtype.itemsize)
    return SplatCloud(names=names, data=np.frombuffer(raw, dtype=dtype, count=count).copy(),
                      header_comments=comments)


def write_splat_ply(path: str | Path, cloud: SplatCloud) -> None:
    tname = {"<f4": "float", "<f8": "double", "u1": "uchar", "<i4": "int"}
    lines = ["ply", "format binary_little_endian 1.0"]
    lines += [f"comment {c}" for c in cloud.header_comments]
    lines.append(f"element vertex {len(cloud.data)}")
    for n in cloud.names:
        lines.append(f"property {tname[cloud.data.dtype[n].str]} {n}")
    lines.append("end_header")
    with Path(path).open("wb") as fh:
        fh.write(("\n".join(lines) + "\n").encode("ascii"))
        fh.write(cloud.data.tobytes())


def arrange_splats(cloud: SplatCloud, boxes: list[Box], floor_y: float,
                   moves: list[Move]) -> SplatCloud:
    """家具を動かした splat を返す。

    位置と回転（クォータニオン）を回す。**球面調和（SH）は回さない。**
    平行移動だけなら影響はなく、回転させると視線依存の色がわずかにずれる。
    正しく扱うには SH の回転が必要で、次の課題。
    """
    out = cloud.data.copy()
    _, masks = split_splats(cloud.xyz, boxes, floor_y)
    by_id = {m.identifier: m for m in moves}
    has_rot = all(f"rot_{i}" in cloud.names for i in range(4))

    for b in boxes:
        mv = by_id.get(b.identifier) or next(
            (m for m in moves if b.identifier.startswith(m.identifier)), None)
        if mv is None or not (mv.dx or mv.dz or mv.dyaw):
            continue
        sel = masks[b.identifier]
        if not sel.any():
            continue
        M = move_matrix(b, mv.dx, mv.dz, mv.dyaw)
        p = np.stack([out["x"][sel], out["y"][sel], out["z"][sel]], axis=1).astype(np.float64)
        p = p @ M[:3, :3].T + M[:3, 3]
        out["x"][sel], out["y"][sel], out["z"][sel] = p[:, 0], p[:, 1], p[:, 2]

        if has_rot and mv.dyaw:
            # Y 軸まわり dyaw の回転を表すクォータニオン (w, x, y, z)
            h = np.radians(mv.dyaw) / 2
            q = np.array([np.cos(h), 0.0, np.sin(h), 0.0])
            cur = np.stack([out[f"rot_{i}"][sel] for i in range(4)], axis=1).astype(np.float64)
            new = _quat_mul(q, cur)
            for i in range(4):
                out[f"rot_{i}"][sel] = new[:, i]

    return SplatCloud(names=cloud.names, data=out, header_comments=cloud.header_comments)


def _quat_mul(q: np.ndarray, r: np.ndarray) -> np.ndarray:
    """q（1 個）を r（N 個）に左から掛ける。並びは (w, x, y, z)。"""
    w1, x1, y1, z1 = q
    w2, x2, y2, z2 = r[:, 0], r[:, 1], r[:, 2], r[:, 3]
    return np.stack([
        w1*w2 - x1*x2 - y1*y2 - z1*z2,
        w1*x2 + x1*w2 + y1*z2 - z1*y2,
        w1*y2 - x1*z2 + y1*w2 + z1*x2,
        w1*z2 + x1*y2 - y1*x2 + z1*w2,
    ], axis=1)
