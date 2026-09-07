"""家具の切り分けと移動のテスト。

**平面図で家具を動かすと 3D 側も動く**という機能の土台なので、
ここが黙って壊れると「動かしたのに何も動かない」「家具が部屋の外へ飛ぶ」
といった形で表に出る。目視では気づきにくいものを押さえる:

- 向き付き境界箱の内外判定（回転した箱で軸並行として判定すると誤る）
- 回転が**家具自身の中心まわり**であること（world 原点まわりだと飛ぶ）
- 移動で高さが変わらないこと（床から浮く／沈む）
- 床付近の面を家具に含めないこと（椅子が床を引きずる）
- 編集器が識別子を 8 桁に切るので前方一致で照合すること
"""

from __future__ import annotations

import json
import math

import numpy as np
import pytest

from mdr2colmap import segment
from mdr2colmap.mesh import Mesh


def _column_major(rows):
    return np.array(rows, float).T.reshape(-1).tolist()


def _object(ident, center, dims, yaw_deg=0.0, category="table", confidence="high"):
    a = math.radians(yaw_deg)
    ca, sa = math.cos(a), math.sin(a)
    # 列 0 = 幅方向、列 1 = 上、列 2 = 奥行方向
    rows = [
        [ca, 0.0, -sa, center[0]],
        [0.0, 1.0, 0.0, center[1]],
        [sa, 0.0, ca, center[2]],
        [0.0, 0.0, 0.0, 1.0],
    ]
    return {
        "identifier": ident,
        "category": {category: {}},
        "dimensions": list(dims),
        "transform": _column_major(rows),
        "confidence": {confidence: {}},
    }


@pytest.fixture
def room_json(tmp_path):
    """床 Y=0。中心 (1, 0.4, 2) に 1.0×0.8×0.6 の台を 45 度で置く。"""
    data = {
        "walls": [], "doors": [], "windows": [], "openings": [], "floors": [],
        "objects": [_object("OBJ-AAAAAAAA", [1.0, 0.4, 2.0], [1.0, 0.8, 0.6], 45.0)],
    }
    p = tmp_path / "room.json"
    p.write_text(json.dumps(data))
    return p


def test_box_axes_are_unit_and_oriented(room_json):
    b = segment.boxes_from_room(room_json)[0]
    assert b.identifier == "OBJ-AAAAAAAA"
    assert b.category == "table"
    assert b.center == pytest.approx([1.0, 0.4, 2.0], abs=1e-6)
    assert b.half == pytest.approx([0.5, 0.4, 0.3], abs=1e-6)
    # 各軸が単位ベクトル
    for i in range(3):
        assert np.linalg.norm(b.axes[:, i]) == pytest.approx(1.0, abs=1e-6)
    # 幅方向が 45 度傾いている
    assert b.axes[0, 0] == pytest.approx(math.cos(math.radians(45)), abs=1e-6)


def test_rotated_box_rejects_points_a_naive_aabb_would_accept(room_json):
    """回転した箱を軸並行として判定すると、角の外側を取り込んでしまう。"""
    b = segment.boxes_from_room(room_json)[0]
    # 箱の外接直方体の角。45 度回転した箱の内部ではない。
    corner = np.array([[1.0 + 0.55, 0.4, 2.0 + 0.55]])
    assert not b.contains(corner)[0]
    # 幅方向に沿った点は内部
    along = b.center + b.axes[:, 0] * 0.4
    assert b.contains(along.reshape(1, 3))[0]


def test_floor_faces_stay_with_the_room(room_json):
    """床付近の面は家具に入れない。入れると椅子が床を引きずる。"""
    b = segment.boxes_from_room(room_json)[0]
    # 箱の中に、床すぐ上と、十分高い位置に三角形を 1 枚ずつ置く
    eps = segment.FLOOR_MARGIN / 2
    verts = np.array([
        [1.0, eps, 2.0], [1.05, eps, 2.0], [1.0, eps, 2.05],        # 床すぐ上
        [1.0, 0.4, 2.0], [1.05, 0.4, 2.0], [1.0, 0.4, 2.05],        # 家具の高さ
    ], np.float32)
    faces = np.array([[0, 1, 2], [3, 4, 5]], np.int64)
    res = segment.split_mesh(Mesh(vertices=verts, faces=faces), [b], floor_y=0.0)

    assert len(res.parts[b.identifier].faces) == 1, "家具は高い方の 1 枚だけ"
    assert len(res.remainder.faces) == 1, "床付近の 1 枚は部屋に残る"
    assert res.floor_excluded == 1
    assert res.parts[b.identifier].vertices[:, 1].min() > segment.FLOOR_MARGIN / 2


def test_split_conserves_every_face(room_json):
    b = segment.boxes_from_room(room_json)[0]
    rng = np.random.default_rng(0)
    verts = rng.uniform(-1, 4, size=(300, 3)).astype(np.float32)
    faces = rng.integers(0, 300, size=(120, 3)).astype(np.int64)
    mesh = Mesh(vertices=verts, faces=faces)
    res = segment.split_mesh(mesh, [b], floor_y=0.0)
    total = len(res.remainder.faces) + sum(len(m.faces) for m in res.parts.values())
    assert total == len(faces), "面が消えたり増えたりしてはいけない"


def test_move_rotates_about_the_object_center(room_json):
    """回転は家具の中心まわり。world 原点まわりだと部屋の外へ飛ぶ。"""
    b = segment.boxes_from_room(room_json)[0]
    M = segment.move_matrix(b, 0.0, 0.0, 90.0)
    # 中心そのものは動かない（平行移動ゼロなので）
    c = np.append(b.center, 1.0)
    moved = M @ c
    assert moved[0] == pytest.approx(b.center[0], abs=1e-6)
    assert moved[2] == pytest.approx(b.center[2], abs=1e-6)


def test_move_keeps_height(room_json):
    b = segment.boxes_from_room(room_json)[0]
    M = segment.move_matrix(b, 1.3, -0.7, 37.0)
    pts = np.array([[1.0, 0.4, 2.0], [1.4, 0.75, 2.2]])
    out = pts @ M[:3, :3].T + M[:3, 3]
    assert out[:, 1] == pytest.approx(pts[:, 1], abs=1e-6), "高さは変えない"


def test_pure_translation_moves_exactly(room_json):
    b = segment.boxes_from_room(room_json)[0]
    M = segment.move_matrix(b, 0.5, -0.25, 0.0)
    p = np.array([[1.0, 0.4, 2.0]])
    out = p @ M[:3, :3].T + M[:3, 3]
    assert out[0] == pytest.approx([1.5, 0.4, 1.75], abs=1e-6)


def test_moves_match_truncated_identifiers(room_json, tmp_path):
    """編集器は識別子を 8 桁に切る。完全一致だけ見ると黙って動かない。"""
    b = segment.boxes_from_room(room_json)[0]
    moves_file = tmp_path / "moves.json"
    moves_file.write_text(json.dumps({
        "moved": [{"id": b.identifier[:8], "delta": {"dx": 1.0, "dz": 0.0, "dyaw": 0.0}}]
    }))
    moves = segment.load_moves(moves_file)
    assert moves[0].identifier == b.identifier[:8]

    verts = np.array([[1.0, 0.4, 2.0], [1.05, 0.4, 2.0], [1.0, 0.4, 2.05]], np.float32)
    mesh = Mesh(vertices=verts, faces=np.array([[0, 1, 2]], np.int64))
    merged = segment.arrange_mesh(mesh, [b], 0.0, moves)
    assert merged.vertices[:, 0].min() == pytest.approx(2.0, abs=1e-5), \
        "前方一致で照合できていれば X が +1.0 動く"


def test_ply_mesh_round_trip(tmp_path):
    verts = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 1]], np.float32)
    faces = np.array([[0, 1, 2], [1, 3, 2]], np.int64)
    p = tmp_path / "m.ply"
    segment.write_ply_mesh(p, Mesh(vertices=verts, faces=faces))

    from mdr2colmap.mesh import read_ply_mesh
    back = read_ply_mesh(p)
    assert back.vertices == pytest.approx(verts)
    assert np.array_equal(back.faces, faces)


def test_quaternion_multiply_matches_rotation_composition():
    """Y 軸まわり 90 度を 2 回で 180 度になる。"""
    h = math.radians(90) / 2
    q = np.array([math.cos(h), 0.0, math.sin(h), 0.0])
    once = segment._quat_mul(q, np.array([[1.0, 0.0, 0.0, 0.0]]))
    twice = segment._quat_mul(q, once)
    # 180 度 = (cos90, 0, sin90, 0) = (0, 0, 1, 0)
    assert abs(twice[0, 0]) == pytest.approx(0.0, abs=1e-6)
    assert abs(twice[0, 2]) == pytest.approx(1.0, abs=1e-6)


def test_splat_split_excludes_floor_and_assigns_once(room_json):
    b = segment.boxes_from_room(room_json)[0]
    xyz = np.array([
        [1.0, 0.4, 2.0],                       # 箱の中、床から離れている
        [1.0, segment.FLOOR_MARGIN / 2, 2.0],  # 箱の中だが床付近
        [5.0, 0.4, 5.0],                       # 箱の外
    ])
    room_mask, masks = segment.split_splats(xyz, [b], floor_y=0.0)
    assert masks[b.identifier].tolist() == [True, False, False]
    assert room_mask.tolist() == [False, True, True]


# -- 上に乗っている物を運ぶ --------------------------------------------------


class _Wall:
    """`roomplan.Wall` の最小の代役。`carry_mask` は p0/p1 だけ使う。"""

    def __init__(self, p0, p1):
        self.p0 = np.array(p0, float)
        self.p1 = np.array(p1, float)


def _tri(x, y, z, size=0.02):
    """指定位置に小さな三角形 1 枚を作る頂点を返す。"""
    return [[x, y, z], [x + size, y, z], [x, y, z + size]]


def test_carry_takes_contacting_stack_and_stops_at_a_gap():
    """接触して積み上がる分だけ運び、空白で止める。

    素朴に「天板の上の柱」を全部運ぶと、離れた壁の物まで巻き込む。
    実測でベッドの上に天板から +1.76m まで面が残っていた。
    """
    b = segment.Box(
        identifier="T", category="table",
        center=np.array([0.0, 0.35, 0.0]), axes=np.eye(3),
        half=np.array([0.5, 0.35, 0.4]),
    )
    y_top = 0.7
    verts, faces = [], []

    def add(x, y, z):
        i = len(verts)
        verts.extend(_tri(x, y, z))
        faces.append([i, i + 1, i + 2])

    # 天板の直上に 4 層ぶん積む（接触している荷物）
    for n in range(4):
        add(0.0, y_top + 0.01 + n * segment.CARRY_LAYER, 0.0)
    # 大きく離れた高さに 1 枚（別物。運んではいけない）
    add(0.0, y_top + 0.60, 0.0)

    mesh = Mesh(vertices=np.array(verts, np.float32), faces=np.array(faces, np.int64))
    walls = [_Wall([-3, -3], [3, -3])]        # 遠い壁
    res = segment.split_mesh(mesh, [b], floor_y=0.0, walls=walls, ceiling_y=2.4)

    assert len(res.parts["T"].faces) == 4, "接触している 4 層だけ運ぶ"
    assert len(res.remainder.faces) == 1, "空白の先にある 1 枚は残す"


def test_carry_does_not_take_wall_faces():
    """壁際は運ばない。運ぶと壁が裂ける。"""
    b = segment.Box(
        identifier="S", category="storage",
        center=np.array([0.0, 0.5, 0.0]), axes=np.eye(3),
        half=np.array([0.4, 0.5, 0.3]),
    )
    verts, faces = [], []
    i = len(verts)
    # 箱の外（膨張後の上端 1.02 より上）だが、壁から 2cm（WALL_CLEARANCE 未満）
    verts.extend(_tri(0.0, 1.06, 0.28))
    faces.append([i, i + 1, i + 2])
    mesh = Mesh(vertices=np.array(verts, np.float32), faces=np.array(faces, np.int64))
    walls = [_Wall([-3.0, 0.30], [3.0, 0.30])]      # z=0.30 に壁
    res = segment.split_mesh(mesh, [b], floor_y=0.0, walls=walls, ceiling_y=2.4)

    assert "S" not in res.parts or len(res.parts["S"].faces) == 0
    assert len(res.remainder.faces) == 1


def test_carry_is_off_when_walls_are_not_given():
    """壁を渡さなければ箱の中だけ。既定の挙動を変えない。"""
    b = segment.Box(
        identifier="T", category="table",
        center=np.array([0.0, 0.35, 0.0]), axes=np.eye(3),
        half=np.array([0.5, 0.35, 0.4]),
    )
    verts = _tri(0.0, 0.72, 0.0)
    mesh = Mesh(vertices=np.array(verts, np.float32), faces=np.array([[0, 1, 2]], np.int64))
    res = segment.split_mesh(mesh, [b], floor_y=0.0)
    assert len(res.remainder.faces) == 1, "carry を渡さなければ運ばない"


def test_carry_does_not_steal_from_another_object():
    """隣の家具を荷物として奪わない。箱の割り当てが先。"""
    low = segment.Box(identifier="LOW", category="table",
                      center=np.array([0.0, 0.2, 0.0]), axes=np.eye(3),
                      half=np.array([0.5, 0.2, 0.4]))
    tall = segment.Box(identifier="TALL", category="storage",
                       center=np.array([0.0, 0.7, 0.0]), axes=np.eye(3),
                       half=np.array([0.3, 0.7, 0.2]))
    # 低い箱の真上、かつ高い箱の中にある面
    verts = _tri(0.0, 0.5, 0.0)
    mesh = Mesh(vertices=np.array(verts, np.float32), faces=np.array([[0, 1, 2]], np.int64))
    walls = [_Wall([-3, -3], [3, -3])]
    res = segment.split_mesh(mesh, [low, tall], floor_y=0.0, walls=walls, ceiling_y=2.4)

    assert len(res.parts.get("TALL", Mesh(np.zeros((0, 3)), np.zeros((0, 3), np.int64))).faces) == 1
    assert "LOW" not in res.parts or len(res.parts["LOW"].faces) == 0


# -- 環境の帯を家具から除外する ----------------------------------------------


def test_environment_mask_excludes_wall_floor_ceiling():
    walls = [_Wall([-3.0, 0.0], [3.0, 0.0])]        # z=0 に壁
    pts = np.array([
        [0.0, 1.0, 0.02],      # 壁から 2cm -> 環境
        [0.0, 1.0, 1.00],      # 壁から 1m  -> 環境でない
        [0.0, 0.01, 1.00],     # 床すぐ上   -> 環境
        [0.0, 2.35, 1.00],     # 天井すぐ下 -> 環境
    ])
    env = segment.environment_mask(pts, floor_y=0.0, ceiling_y=2.4, walls=walls)
    assert env.tolist() == [True, False, True, True]


def test_wall_adjacent_furniture_does_not_take_the_wall():
    """壁付きの家具の箱には壁が入る。帯で除外しないと壁が裂ける。

    実測で収納に割り当てた面積の 45.6% が壁から 10cm 以内だった。
    """
    b = segment.Box("S", "storage", np.array([0.0, 1.0, 0.15]), np.eye(3),
                    np.array([0.4, 1.0, 0.2]))
    walls = [_Wall([-3.0, 0.34], [3.0, 0.34])]      # 箱の背面ぎりぎりに壁
    verts, faces = [], []

    def add(z):
        i = len(verts)
        verts.extend(_tri(0.0, 1.0, z))
        faces.append([i, i + 1, i + 2])

    add(0.32)      # 壁から 2cm。箱の中だが壁面
    add(0.05)      # 箱の中で壁から離れている
    mesh = Mesh(vertices=np.array(verts, np.float32), faces=np.array(faces, np.int64))

    res = segment.split_mesh(mesh, [b], floor_y=0.0, walls=walls, ceiling_y=2.4)
    assert len(res.parts["S"].faces) == 1, "壁面は家具に入れない"
    assert len(res.remainder.faces) == 1


def test_veto_is_off_without_walls():
    """壁を渡さなければ従来どおり箱の中だけを取る。既定を変えない。"""
    b = segment.Box("S", "storage", np.array([0.0, 1.0, 0.15]), np.eye(3),
                    np.array([0.4, 1.0, 0.2]))
    verts = _tri(0.0, 1.0, 0.32)
    mesh = Mesh(vertices=np.array(verts, np.float32), faces=np.array([[0, 1, 2]], np.int64))
    res = segment.split_mesh(mesh, [b], floor_y=0.0)
    assert len(res.parts["S"].faces) == 1


# -- 箱が重なるとき ----------------------------------------------------------


def test_overlapping_boxes_prefer_the_smaller_one():
    """入れ子の箱では、小さい箱が勝つ。

    机の下の椅子で実際に起きた。椅子の箱の 56% が机の箱と重なっており、
    「先に来た箱が勝つ」だと椅子は自分の箱の 51% しか得られなかった。

    箱の大きさで正規化した深さ（|local|/half）ではこれは解けない。同じ絶対
    距離なら大きい箱のほうが浅いので、**大きい箱が選ばれてしまう**。
    """
    big = segment.Box("BIG", "table", np.zeros(3), np.eye(3), np.array([1.0, 1.0, 1.0]))
    small = segment.Box("SML", "chair", np.zeros(3), np.eye(3), np.array([0.2, 1.0, 0.2]))
    # 小さい箱のほぼ中心。大きい箱では中心からの相対位置が浅い
    verts = _tri(0.02, 0.5, 0.02)
    mesh = Mesh(vertices=np.array(verts, np.float32), faces=np.array([[0, 1, 2]], np.int64))

    for boxes in ([big, small], [small, big]):        # 並びを変えても同じ結果
        res = segment.split_mesh(mesh, boxes, floor_y=-1.0)
        assert len(res.parts.get("SML", Mesh(np.zeros((0, 3)), np.zeros((0, 3), np.int64))).faces) == 1, \
            "小さい箱に深く入っている面は小さい箱へ"
        assert "BIG" not in res.parts or len(res.parts["BIG"].faces) == 0


def test_face_outside_the_small_box_goes_to_the_big_one():
    big = segment.Box("BIG", "table", np.zeros(3), np.eye(3), np.array([1.0, 1.0, 1.0]))
    small = segment.Box("SML", "chair", np.zeros(3), np.eye(3), np.array([0.2, 1.0, 0.2]))
    verts = _tri(0.8, 0.5, 0.0)                      # 小さい箱の外、大きい箱の中
    mesh = Mesh(vertices=np.array(verts, np.float32), faces=np.array([[0, 1, 2]], np.int64))
    res = segment.split_mesh(mesh, [big, small], floor_y=-1.0)
    assert len(res.parts["BIG"].faces) == 1
    assert "SML" not in res.parts or len(res.parts["SML"].faces) == 0


def test_top_surface_stays_with_its_own_box():
    """小さい箱が重なっていても、大きい箱の天板は大きい箱に残る。

    実測（room-33d49373）では机と椅子の重なり 1,264 面のうち 516 面が
    机の天板の高さ（床上 70〜80cm、箱の上端 -0.877）にあった。
    「小さい箱が勝つ」だけだと椅子が天板を奪い、机に穴が空く。
    天板は「箱の上端付近にある水平な面」で見分ける。
    """
    table = segment.Box("TBL", "table", np.zeros(3), np.eye(3), np.array([1.0, 0.4, 1.0]))
    chair = segment.Box("CHR", "chair", np.zeros(3), np.eye(3), np.array([0.2, 0.9, 0.2]))
    # 机の箱の上端 (y=0.4) にある水平な面。椅子の箱にも入っている
    top = [[-0.1, 0.4, -0.1], [0.1, 0.4, -0.1], [0.0, 0.4, 0.1]]
    # 机の天板より下、椅子の箱の中の面（座面）
    seat = _tri(0.0, 0.0, 0.0)
    mesh = Mesh(vertices=np.array(top + seat, np.float32),
                faces=np.array([[0, 1, 2], [3, 4, 5]], np.int64))

    for boxes in ([table, chair], [chair, table]):
        res = segment.split_mesh(mesh, boxes, floor_y=-1.0)
        assert len(res.parts["TBL"].faces) == 1, "天板は机に残る"
        assert len(res.parts["CHR"].faces) == 1, "座面は椅子へ"


def test_confidence_is_read_from_room_json(tmp_path):
    """RoomPlan の信頼度を箱に持つ。

    実測で `medium` の箱は物体を囲えていなかった（椅子が Z 方向に 35cm ずれ）。
    人が確認すべき対象を出すために、信頼度を落とさず運ぶ。
    """
    room = tmp_path / "room.json"
    room.write_text(json.dumps({"objects": [
        _object("A", [0.0, 0.4, 0.0], [1.0, 0.8, 1.0], category="table", confidence="high"),
        _object("B", [2.0, 0.5, 0.0], [0.5, 1.0, 0.5], category="chair", confidence="medium"),
    ]}))
    boxes = {b.identifier: b for b in segment.boxes_from_room(room)}
    assert boxes["A"].confidence == "high"
    assert boxes["B"].confidence == "medium"


def test_box_fix_shifts_the_center(tmp_path):
    """箱の補正で中心が動く。半径と向きは変えない。

    RoomPlan の箱がずれていても、寸法と向きは合っていることが多い
    （椅子は 0.54x1.14x0.64 が実物どおりで、位置だけ 35cm 外れていた）。
    """
    room = tmp_path / "room.json"
    room.write_text(json.dumps({"objects": [
        _object("B", [0.0, 0.5, 2.6], [0.5, 1.0, 0.6], category="chair", confidence="medium"),
    ]}))
    plain = segment.boxes_from_room(room)[0]
    fixed = segment.boxes_from_room(room, fixes={"B": {"dz": -0.35}})[0]
    assert fixed.center == pytest.approx([0.0, 0.5, 2.25], abs=1e-6)
    assert fixed.half == pytest.approx(plain.half)
    assert fixed.axes == pytest.approx(plain.axes)
    # 補正の対象でない箱は動かない
    other = segment.boxes_from_room(room, fixes={"別の識別子": {"dz": -1.0}})[0]
    assert other.center == pytest.approx(plain.center)


def _strip(y, x0, x1, z=0.0, step=0.05):
    """X 方向に辺を共有して連なる三角形の帯を作る。戻り値は (頂点, 面)。"""
    xs = np.arange(x0, x1 + 1e-9, step)
    verts, faces = [], []
    for i, x in enumerate(xs):
        verts += [[x, y, z - 0.02], [x, y, z + 0.02]]
        if i:
            a, b = 2 * (i - 1), 2 * (i - 1) + 1
            faces += [[a, b, a + 2], [b, a + 3, a + 2]]
    return (np.array(verts, np.float32),
            np.array(faces, np.int64).reshape(-1, 3))


def test_grow_takes_the_part_sticking_out_of_the_box():
    """箱からはみ出した部分が、辺の隣接をたどって取り込まれる。

    椅子の実測: 箱の幅 539mm に対しアームレストが片側 +14.3cm はみ出し、
    750 面 (0.251 m2) が部屋側に残った。動かすと破片が置き去りになる。
    """
    V, F = _strip(0.5, -0.20, 0.34)          # 箱は |x| <= 0.20
    box = segment.Box("B", "chair", np.array([0.0, 0.5, 0.0]), np.eye(3),
                      np.array([0.20, 0.5, 0.10]))
    cen = V[F].mean(axis=1)
    plain = segment.assign_faces(cen, [box], floor_y=0.0)
    a = segment.assign_faces(cen, [box], floor_y=0.0,
                             adj=segment.face_adjacency(F, V))
    assert int((a == 0).sum()) > int((plain == 0).sum()), "はみ出した帯を取り込むべき"
    over = cen[a == 0][:, 0]
    assert over.max() > 0.20 * segment.BOX_INFLATE, "箱の外まで伸びている"
    assert over.max() <= 0.20 + segment.GROW_MARGIN + 1e-6, "範囲の外へは行かない"


def test_grow_stops_at_the_margin():
    """繋がっていても、箱の外側 GROW_MARGIN を越えたら取り込まない。

    溶接後のメッシュでは机・椅子・ベッドが 1 つの連結成分だった。
    範囲を切らないと部屋全体へ流れる。
    """
    V, F = _strip(0.5, -0.20, 1.50)
    box = segment.Box("B", "chair", np.array([0.0, 0.5, 0.0]), np.eye(3),
                      np.array([0.20, 0.5, 0.10]))
    cen = V[F].mean(axis=1)
    a = segment.assign_faces(cen, [box], floor_y=0.0,
                             adj=segment.face_adjacency(F, V))
    assert cen[a == 0][:, 0].max() <= 0.20 + segment.GROW_MARGIN + 1e-6
    assert int((a < 0).sum()) > 0, "遠い側は部屋に残る"


def test_grow_does_not_cross_the_floor():
    """床に近い水平面は障壁になり、そこから先へは広がらない。

    椅子のキャスターはラグに接している。障壁を置かないと床の混入が
    0.503 -> 0.722 m2、壁の混入が 0.467 -> 0.969 m2 に増えた（実測）。
    """
    # 箱の中の種（床上 0.3m）から、床上 3cm の水平な帯（床/ラグ）へ繋がる形。
    seed_v, seed_f = _strip(0.30, -0.10, 0.10)
    floor_v, floor_f = _strip(0.03, -0.20, 0.60)
    V = np.vstack([seed_v, floor_v]).astype(np.float32)
    F = np.vstack([seed_f, floor_f + len(seed_v)]).astype(np.int64)
    # 種と床の帯を 1 枚の面で繋ぐ（辺の共有ではなく頂点の共有で足りる場所は
    # 隣接表に出ないので、明示的に橋を架ける）
    bridge = np.array([[0, 1, len(seed_v)]], np.int64)
    F = np.vstack([F, bridge])
    box = segment.Box("B", "chair", np.array([0.0, 0.3, 0.0]), np.eye(3),
                      np.array([0.20, 0.3, 0.10]))
    cen = V[F].mean(axis=1)
    tri = V[F]
    nrm = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    nrm /= np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-12)
    walls = [_Wall([-5.0, -5.0], [-5.0, 5.0]), _Wall([5.0, -5.0], [5.0, 5.0])]
    a = segment.assign_faces(cen, [box], floor_y=0.0, walls=walls, ceiling_y=2.4,
                             normals=nrm, adj=segment.face_adjacency(F, V))
    taken = cen[a == 0]
    assert not ((taken[:, 1] < 0.10) & (np.abs(taken[:, 0]) > 0.21)).any(), \
        "床の帯を箱の外まで辿ってはいけない"


def test_grow_needs_edge_adjacency():
    """辺で繋がっていない島は取り込まない。距離だけでは判定しない。"""
    V, F = _strip(0.5, -0.20, 0.10)
    island_v, island_f = _strip(0.5, 0.26, 0.40)
    V2 = np.vstack([V, island_v]).astype(np.float32)
    F2 = np.vstack([F, island_f + len(V)]).astype(np.int64)
    box = segment.Box("B", "chair", np.array([0.0, 0.5, 0.0]), np.eye(3),
                      np.array([0.20, 0.5, 0.10]))
    cen = V2[F2].mean(axis=1)
    a = segment.assign_faces(cen, [box], floor_y=0.0,
                             adj=segment.face_adjacency(F2, V2))
    assert (cen[a == 0][:, 0] < 0.25).all(), "離れた島は取り込まない"
