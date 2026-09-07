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
    #: RoomPlan の推定信頼度（"high" / "medium" / "low"）。
    #:
    #: **箱の当たり外れとよく対応する。** 実測（room-33d49373）で、
    #: `high` の 2 つ（収納・テーブル）は最良位置とのずれが 5cm 以内、
    #: `medium` の椅子は Z 方向に 35cm ずれて箱が椅子を囲っていなかった。
    #: `medium` は人が確認する対象として扱う。
    confidence: str = "unknown"

    def contains(self, points: np.ndarray, inflate: float = BOX_INFLATE) -> np.ndarray:
        """点群が箱の中にあるかを返す。"""
        local = (points - self.center) @ self.axes
        return np.all(np.abs(local) <= self.half * inflate, axis=1)

    @property
    def floor_y(self) -> float:
        """箱の下端の高さ。"""
        return float(self.center[1] - self.half[1])


def boxes_from_room(room_json: str | Path,
                    fixes: dict[str, dict] | None = None) -> list[Box]:
    """`room.json` の objects を境界箱にする。

    `fixes` は識別子ごとの補正 `{"dx":…, "dy":…, "dz":…}`（world 座標、m）。
    **RoomPlan の箱は物体を囲えていないことがある。** 実測では椅子が Z 方向に
    35cm ずれ、箱の中身が机の下面と床になっていた。自動補正は試したが、
    占有を最大化すると信頼できる箱（`high`）まで 30cm 動いてしまい、
    目視で誤りと確認した。よって**人が直した結果を受け取る**形にする。
    """
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
        conf = o.get("confidence")
        ident = str(o["identifier"])
        center = T[:3, 3].copy()
        fix = (fixes or {}).get(ident)
        if fix:
            center = center + np.array([float(fix.get("dx", 0.0)),
                                        float(fix.get("dy", 0.0)),
                                        float(fix.get("dz", 0.0))])
        out.append(Box(
            identifier=ident,
            category=next(iter(cat), "unknown") if isinstance(cat, dict) else str(cat),
            center=center,
            axes=axes / norms,
            half=np.array(o["dimensions"], float) / 2,
            confidence=(next(iter(conf), "unknown") if isinstance(conf, dict)
                        else str(conf or "unknown")),
        ))
    return out


def load_box_fixes(path: str | Path) -> dict[str, dict]:
    """箱の補正ファイルを読む。`{識別子: {"dx":…, "dy":…, "dz":…}}`。"""
    import json

    data = json.loads(Path(path).read_text())
    return {str(k): dict(v) for k, v in data.get("boxes", data).items()}


@dataclass
class SplitMesh:
    """切り分けた結果。`remainder` が部屋（壁・床・天井）。"""

    remainder: Mesh
    parts: dict[str, Mesh]
    #: 各家具に割り当てた面数。振り分けが妥当かの確認用。
    counts: dict[str, int]
    #: 床付近で除外した面数。
    floor_excluded: int


def environment_mask(centroids: np.ndarray, floor_y: float, ceiling_y: float,
                     walls, floor_margin: float = FLOOR_MARGIN) -> np.ndarray:
    """床・壁・天井の帯。**家具に割り当ててはいけない領域。**

    箱は物体の境界ではないので、壁付きの家具の箱には壁が入る。
    実在する面（床平面・壁平面）で線を引くのが、幾何側で使える唯一の
    確かな手がかり。
    """
    return ((centroids[:, 1] < floor_y + floor_margin)
            | (centroids[:, 1] > ceiling_y - CEILING_BAND)
            | (_wall_distance(centroids, walls) < WALL_BAND))


def assign_faces(centroids: np.ndarray, boxes: list[Box], floor_y: float,
                 floor_margin: float = FLOOR_MARGIN,
                 walls=None, ceiling_y: float | None = None,
                 normals: np.ndarray | None = None,
                 adj: list[list[int]] | None = None) -> np.ndarray:
    """面（の重心）を家具に振り分ける。戻り値は箱の添字、-1 は部屋。

    `walls` と `ceiling_y` を渡すと:
      - 床・壁・天井の帯を家具から除外する（`environment_mask`）
      - 家具の上に乗っている物を一緒に運ぶ（`carry_mask`）

    渡さなければ箱の中だけを取る（帯の除外も運搬もしない）。
    """
    near_floor = centroids[:, 1] < floor_y + floor_margin
    if walls is not None and ceiling_y is not None:
        env = environment_mask(centroids, floor_y, ceiling_y, walls, floor_margin)
    else:
        env = near_floor

    # **箱が重なるときは「小さい箱を優先」する。ただし天板は守る。**
    #
    # 「先に来た箱が勝つ」だと room.json の並びで結果が変わる。実測で
    # 椅子の箱の 56% が机の箱と重なっており（机は 21%）、机が先に来るため
    # 椅子は自分の箱の 51% しか得られなかった。
    #
    # 正規化した深さ（|local|/half）は使えない。同じ絶対距離なら大きい箱の
    # ほうが相対的に浅くなるので、**大きい箱を選んでしまう**（入れ子に対して逆）。
    #
    # 小さい箱を優先するのが素直だが、それだけでは机の天板を椅子が奪う。
    # 重なり領域の高さ分布（実測）:
    #
    #      0- 10cm  206 面   両者の脚
    #     40- 70cm  536 面   椅子の座面と背もたれ
    #     70- 80cm  516 面   机の天板（77.7cm）
    #
    # 天板は「箱の上端付近にある水平な面」という物理的な手がかりで守れる。
    volume = np.array([float(np.prod(b.half)) for b in boxes])
    contain = np.stack([b.contains(centroids) for b in boxes], axis=1)

    # 小さい箱を優先。含まない箱は +inf。
    cost = np.where(contain, volume[None, :], np.inf)

    if normals is not None:
        # 箱の上端 TOP_TOL 以内にある水平な面は、その箱の天板とみなして守る。
        horiz = np.abs(normals[:, 1]) > TOP_NORMAL
        for i, b in enumerate(boxes):
            top = float(b.center[1] + b.half[1])
            near_top = np.abs(centroids[:, 1] - top) < TOP_TOL
            cost[contain[:, i] & near_top & horiz, i] = -1.0

    best = np.argmin(cost, axis=1)
    has = np.isfinite(cost).any(axis=1)
    assigned = np.where(has & ~env, best.astype(np.int32), -1).astype(np.int32)

    if adj is not None:
        # 箱からはみ出した部分を、隣接をたどって取り込む。運搬より先に行う。
        # 後にすると、荷物として運んだ面から生えて範囲が読めなくなる。
        barrier = (room_like(centroids, normals, floor_y, walls)
                   if normals is not None and walls is not None else None)
        for i, b in enumerate(boxes):
            add = grow_mask(b, centroids, assigned == i, (assigned < 0) & ~env,
                            adj, barrier=barrier)
            assigned[add] = i

    if walls is not None and ceiling_y is not None:
        # 箱の割り当てが終わってから運ぶ。先に運ぶと、隣の家具を
        # 荷物として奪い合う。
        for i, b in enumerate(boxes):
            add = carry_mask(b, centroids, (assigned < 0) & ~env,
                             walls, ceiling_y, own=(assigned == i))
            assigned[add] = i
    return assigned


def split_mesh(mesh: Mesh, boxes: list[Box], floor_y: float,
               floor_margin: float = FLOOR_MARGIN,
               walls=None, ceiling_y: float | None = None) -> SplitMesh:
    """メッシュを家具ごとに切り分ける。

    面は**重心**で振り分ける。頂点単位で判定すると 1 つの面が複数の
    部品にまたがり、どちらに入れるかが決まらない。
    """
    V, F = mesh.vertices, mesh.faces
    tri = V[F]
    centroids = tri.mean(axis=1)
    normals = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
    near_floor = centroids[:, 1] < floor_y + floor_margin
    assigned = assign_faces(centroids, boxes, floor_y, floor_margin, walls, ceiling_y,
                            normals=normals, adj=face_adjacency(F, V))

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
                 moves: list[Move], walls=None, ceiling_y: float | None = None) -> Mesh:
    """家具を動かした 1 枚のメッシュを返す。

    **編集器の識別子は先頭 8 桁に切っている**ので、前方一致で照合する。
    完全一致だけを見ると黙って何も動かない結果になる。
    """
    split = split_mesh(mesh, boxes, floor_y, walls=walls, ceiling_y=ceiling_y)
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


# --- テクスチャ付きメッシュの分割 -------------------------------------------


def split_textured(tm, boxes: list[Box], floor_y: float,
                   floor_margin: float = FLOOR_MARGIN,
                   walls=None, ceiling_y: float | None = None):
    """テクスチャ付きメッシュを家具ごとに分ける。**UV を保つ。**

    アトラスは 1 枚を共有する。UV をそのまま持ち回れば、部品ごとに
    テクスチャを焼き直す必要がない（焼き直すと継ぎ目も変わる）。

    戻り値は `(remainder, {id: part})`。各要素は `(vertices, uvs, faces)`。
    """
    V, F, UV = tm.vertices, tm.faces, tm.uvs
    tri = V[F]
    centroids = tri.mean(axis=1)
    normals = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
    assigned = assign_faces(centroids, boxes, floor_y, floor_margin, walls, ceiling_y,
                            normals=normals, adj=face_adjacency(F, V))

    def take(mask: np.ndarray):
        faces = F[mask]
        if len(faces) == 0:
            return (np.zeros((0, 3), np.float32), np.zeros((0, 2), np.float32),
                    np.zeros((0, 3), np.int64))
        used = np.unique(faces)
        remap = np.full(int(used.max()) + 1, -1, dtype=np.int64)
        remap[used] = np.arange(len(used))
        return V[used].copy(), UV[used].copy(), remap[faces]

    parts = {}
    for i, b in enumerate(boxes):
        sel = assigned == i
        if sel.any():
            parts[b.identifier] = take(sel)
    return take(assigned < 0), parts


def write_multi_glb(path: str | Path, parts: list[tuple[str, tuple]],
                    texture: np.ndarray) -> None:
    """複数の部品を 1 つの GLB に書く。**部品ごとに別ノード**にする。

    ノードを分けるのが要点。Web 側は `node.matrix` を差し替えるだけで
    家具を動かせる。1 つのメッシュにまとめると分けて動かせない。

    テクスチャは 1 枚を共有する。部品ごとに持つと 5 倍に膨らむ。
    """
    import io
    import json
    import struct

    from PIL import Image

    buf = io.BytesIO()
    accessors: list[dict] = []
    views: list[dict] = []
    meshes: list[dict] = []
    nodes: list[dict] = []

    def put(arr: np.ndarray, target: int | None = None) -> int:
        # glTF は 4 バイト境界を要求する
        while buf.tell() % 4:
            buf.write(b"\x00")
        off = buf.tell()
        buf.write(arr.tobytes())
        view = {"buffer": 0, "byteOffset": off, "byteLength": buf.tell() - off}
        if target is not None:
            view["target"] = target
        views.append(view)
        return len(views) - 1

    for name, (v, uv, f) in parts:
        if len(f) == 0:
            continue
        vp = np.ascontiguousarray(v, "<f4")
        vt = np.ascontiguousarray(uv, "<f4")
        vi = np.ascontiguousarray(f, "<u4").ravel()

        a_pos = len(accessors)
        accessors.append({"bufferView": put(vp, 34962), "componentType": 5126,
                          "count": len(vp), "type": "VEC3",
                          "min": vp.min(axis=0).tolist(), "max": vp.max(axis=0).tolist()})
        a_uv = len(accessors)
        accessors.append({"bufferView": put(vt, 34962), "componentType": 5126,
                          "count": len(vt), "type": "VEC2"})
        a_idx = len(accessors)
        accessors.append({"bufferView": put(vi, 34963), "componentType": 5125,
                          "count": len(vi), "type": "SCALAR"})

        meshes.append({"name": name, "primitives": [{
            "attributes": {"POSITION": a_pos, "TEXCOORD_0": a_uv},
            "indices": a_idx, "material": 0,
        }]})
        nodes.append({"name": name, "mesh": len(meshes) - 1})

    img = io.BytesIO()
    Image.fromarray(texture).save(img, format="JPEG", quality=88)
    v_img = put(np.frombuffer(img.getvalue(), np.uint8))

    while buf.tell() % 4:
        buf.write(b"\x00")
    blob = buf.getvalue()

    gltf = {
        "asset": {"version": "2.0", "generator": "madoriba-segment"},
        "scene": 0,
        "scenes": [{"nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": [{"pbrMetallicRoughness": {
            "baseColorTexture": {"index": 0}, "metallicFactor": 0.0,
            "roughnessFactor": 0.9}, "doubleSided": True}],
        "textures": [{"source": 0}],
        "images": [{"bufferView": v_img, "mimeType": "image/jpeg"}],
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(blob)}],
    }

    js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    js += b" " * ((4 - len(js) % 4) % 4)

    # fourCC は文字列から作る。手打ちの 0x46746C67 は T/t を取り違えやすい。
    def four(s: str) -> int:
        return int.from_bytes(s.encode("ascii"), "little")

    total = 12 + 8 + len(js) + 8 + len(blob)
    with Path(path).open("wb") as fh:
        fh.write(struct.pack("<III", four("glTF"), 2, total))
        fh.write(struct.pack("<II", len(js), four("JSON")))
        fh.write(js)
        fh.write(struct.pack("<II", len(blob), four("BIN\x00")))
        fh.write(blob)


# --- 上に乗っている物を一緒に運ぶ -------------------------------------------
#
# RoomPlan の箱は家具そのものの寸法しかないので、机の上のモニタやベッドの寝具は
# 箱の外に出る。そのまま家具だけ動かすと**乗っていた物が空中に取り残される**。
#
# 素朴に「天板の上の柱」を全部運ぶと壊れる。実測（room-33d49373）では
# ベッドの上に 9,566 面が残り、天板から +1.76m まで伸びていた。これは荷物では
# なく壁と空間で、運ぶと壁が裂ける。
#
# **天板から上へ層を積み、最初に空になった層で止める。** 接触しているものだけが
# 連続して積み上がり、離れた物との間には空白ができる。実測のテーブル:
#
#     +0cm 184 / +5cm 193 / ... / +45cm 110 / +50cm 0 ... +120cm 0 / +125cm 18
#
# +45cm まで連続（机上のモニタ）、70cm の空白、その上は壁際の別物。
# ベッドは +30cm で、椅子は +25cm で切れた。収納は天井際なので何も乗らない。

#: 層の厚み。薄すぎると 1 つの物の中で切れ、厚すぎると離れた物を巻き込む。
CARRY_LAYER = 0.05
#: 空白が見つからない場合の打ち切り。壁一面を運ぶ事故を防ぐ最後の砦。
CARRY_MAX = 1.0
#: 壁からこの距離以内は壁面とみなして運ばない。運ぶと壁が裂ける。
WALL_CLEARANCE = 0.10
#: 家具の割り当てから除外する壁帯の幅。
#:
#: **壁付きの家具は壁を大量に連れて行く。** 実測（room-33d49373）で、
#: 収納に割り当てた 4.50 m2 のうち 45.6% が壁から 10cm 以内、
#: テーブルは 23.7% だった。動かすと壁が裂ける。
#:
#: 幅を掃引した結果（混入 = 壁から 2cm 以内で法線が水平な面の面積）:
#:
#:      0cm  混入 0.659 m2 (5.5%)  家具 11.95 m2
#:      4cm  混入 0.000            家具 10.30      <- 採用
#:      7cm  混入 0.000            家具  9.59
#:     10cm  混入 0.000            家具  9.09
#:
#: **4cm で混入がゼロになり、それ以上広げても家具を削るだけ。**
#: 取り除かれるのは壁を向いた皮で、遮蔽されて元々見えない。
WALL_BAND = 0.04
#: 天井帯。天井付近の面も家具に含めない。
CEILING_BAND = 0.10
#: 箱からはみ出した部分を、メッシュの隣接をたどって取り込む距離。
#:
#: **RoomPlan の寸法は物体の外形より小さいことがある。** 実測（room-33d49373）で
#: 椅子の箱は幅 539mm だが、アームレストが片側 +14.3cm はみ出しており、
#: 750 面 (0.251 m2) が部屋側に残った。動かすと椅子の破片が置き去りになる。
#:
#: 箱を膨らませて解こうとすると机と床を巻き込む。**面の隣接をたどれば、
#: 実際に椅子とつながっている面だけを取り込める。** 床・壁の帯と他の家具は
#: 候補から外すので、そこで自然に止まる。
#:
#: **この値には根拠のある止め所がない。** 1 部屋での掃引（2cm〜40cm）で
#: 家具の面積は 11.79 -> 13.14 m2 と単調に増え、床・壁の混入は 0.503 / 0.467 m2
#: から一切動かない。つまり平坦部がなく、大きくすれば取り込みが増えるだけ。
#: 15cm は実測したアームレストのはみ出し +14.3cm を覆う値として選んだにすぎない。
#: **系のなかで最も弱い定数。** 部屋を増やして決め直す必要がある。
GROW_MARGIN = 0.15
#: 取り込みの障壁。**床に近い水平面と壁に近い垂直面は部屋とみなして越えない。**
#:
#: 環境帯（4cm）だけでは足りない。実測（room-33d49373）で、障壁なしの取り込みは
#: 床の混入を 0.503 -> 0.722 m2、壁の混入を 0.467 -> 0.969 m2 に増やした。
#: 椅子のキャスターがラグに接しているので、そこから床へ流れ出る。
#:
#: 代償として、箱の外にあるキャスターの先端（床上 10cm 未満の水平面）は
#: 取り込めない。ラグを持って行くより、爪先を残すほうが良い。
#:
#: 掃引すると 10cm 以上で混入が飽和し（0.10〜0.25 で 0.503 / 0.467 m2 のまま）、
#: 下回ると急に増える（2cm で 0.722 / 0.969）。平坦部の入口にあたる。
GROW_ROOM_BAND = 0.10
#: 床とみなす法線の垂直成分（これ以上なら水平面）。
GROW_FLOOR_NORMAL = 0.85
#: 壁とみなす法線の垂直成分（これ以下なら垂直面）。
GROW_WALL_NORMAL = 0.35
#: 箱の上端からこの距離以内にある水平な面を「天板」とみなす。
TOP_TOL = 0.05
#: 天板と認める法線の垂直成分。
TOP_NORMAL = 0.70
#: 天井付近も運ばない。
CEILING_CLEARANCE = 0.15
#: 天板の外形をこの倍率で広げて判定する。縁に載った物を拾うため。
FOOTPRINT_INFLATE = 1.06


def _wall_distance(points: np.ndarray, walls) -> np.ndarray:
    """各点から最も近い壁までの水平距離。壁は線分 × 高さの面。"""
    d = np.full(len(points), np.inf)
    xz = points[:, [0, 2]]
    for w in walls:
        seg = w.p1 - w.p0
        l2 = float(seg @ seg)
        if l2 < 1e-9:
            continue
        t = np.clip(((xz - w.p0) @ seg) / l2, 0.0, 1.0)
        d = np.minimum(d, np.linalg.norm(xz - (w.p0 + t[:, None] * seg), axis=1))
    return d


def face_adjacency(faces: np.ndarray, vertices: np.ndarray,
                   weld: float = 0.001) -> list[list[int]]:
    """辺を共有する面の隣接表。

    ARKit のメッシュはアンカーの境目で頂点が重複するので、位置を `weld` で
    量子化してから辺を作る。しないとアンカーを跨いだ隣接が切れる。
    """
    key = np.round(vertices.astype(np.float64) / weld).astype(np.int64)
    _, inv = np.unique(key, axis=0, return_inverse=True)
    f = inv.reshape(-1)[faces]
    e = np.sort(np.vstack([f[:, [0, 1]], f[:, [1, 2]], f[:, [2, 0]]]), axis=1)
    fid = np.tile(np.arange(len(faces)), 3)
    order = np.lexsort((e[:, 1], e[:, 0]))
    e, fid = e[order], fid[order]
    same = np.all(e[1:] == e[:-1], axis=1)
    adj: list[list[int]] = [[] for _ in range(len(faces))]
    for i in np.nonzero(same)[0]:
        x, y = int(fid[i]), int(fid[i + 1])
        adj[x].append(y)
        adj[y].append(x)
    return adj


def room_like(centroids: np.ndarray, normals: np.ndarray, floor_y: float,
              walls, band: float | None = None) -> np.ndarray:
    """部屋の面（床・ラグ・壁）とみなせる面。取り込みの障壁になる。

    「近い」だけでは家具の脚も引っかかる。**向きも見る。** 床は水平、
    壁は垂直なので、法線が合っていて近いものだけを部屋とする。
    """
    band = GROW_ROOM_BAND if band is None else band
    flat = np.abs(normals[:, 1]) > GROW_FLOOR_NORMAL
    upright = np.abs(normals[:, 1]) < GROW_WALL_NORMAL
    return ((flat & (centroids[:, 1] - floor_y < band))
            | (upright & (_wall_distance(centroids, walls) < band)))


def grow_mask(box: Box, centroids: np.ndarray, seed: np.ndarray,
              available: np.ndarray, adj: list[list[int]],
              barrier: np.ndarray | None = None,
              margin: float | None = None) -> np.ndarray:
    """箱の中の面から辺をたどって、はみ出した部分を取り込む。

    `seed` はすでにこの箱に属している面、`available` はまだどの家具にも
    属さず環境帯でもない面、`barrier` は越えてはいけない面（`room_like`）。
    取り込む範囲は箱の外側 `margin` までに限る。
    **範囲を切らないと、繋がったメッシュを伝って部屋全体に流れる**
    （実測で机・椅子・ベッドは溶接後も 1 つの連結成分だった）。
    """
    from collections import deque

    margin = GROW_MARGIN if margin is None else margin
    local = np.abs((centroids - box.center) @ box.axes)
    near = np.all(local <= box.half + margin, axis=1)
    cand = available & near
    if barrier is not None:
        cand = cand & ~barrier
    out = np.zeros(len(centroids), bool)
    q = deque(int(i) for i in np.nonzero(seed)[0])
    seen = seed.copy()
    while q:
        i = q.popleft()
        for nb in adj[i]:
            if seen[nb] or not cand[nb]:
                continue
            seen[nb] = True
            out[nb] = True
            q.append(nb)
    return out


def carry_mask(box: Box, centroids: np.ndarray, available: np.ndarray,
               walls, ceiling_y: float, own: np.ndarray | None = None) -> np.ndarray:
    """`box` の上に乗っていて一緒に動かすべき面を選ぶ。

    `available` はまだどの家具にも属していない面のマスク。
    `own` は既にこの箱に属している面。**層が空かどうかの判定には `own` も数える。**
    数えないと、天板付近の層を箱が取り切っている場合に最初の層が空と判定され、
    走査が即座に止まって何も運べない。
    """
    y_top = float(box.center[1] + box.half[1])
    local = (centroids - box.center) @ box.axes
    foot = ((np.abs(local[:, 0]) <= box.half[0] * FOOTPRINT_INFLATE) &
            (np.abs(local[:, 2]) <= box.half[2] * FOOTPRINT_INFLATE))

    cand = (available & foot
            & (centroids[:, 1] > y_top - CARRY_LAYER * 0.4)
            & (centroids[:, 1] < ceiling_y - CEILING_CLEARANCE)
            & (_wall_distance(centroids, walls) >= WALL_CLEARANCE))
    if not cand.any():
        return np.zeros(len(centroids), bool)

    height = centroids[:, 1] - y_top
    # 箱自身の面も「その層に物がある」根拠として数える（運ぶ対象には入れない）
    support = own & foot if own is not None else np.zeros(len(centroids), bool)

    out = np.zeros(len(centroids), bool)
    layer = 0
    while layer * CARRY_LAYER < CARRY_MAX:
        lo = layer * CARRY_LAYER - CARRY_LAYER * 0.4
        hi = lo + CARRY_LAYER
        in_layer = (height >= lo) & (height < hi)
        sel = cand & in_layer
        if not sel.any() and not (support & in_layer).any():
            break                    # 空白の層。ここで接触が途切れている
        out |= sel
        layer += 1
    return out
