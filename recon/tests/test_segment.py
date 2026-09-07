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


def _object(ident, center, dims, yaw_deg=0.0, category="table"):
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
        "confidence": {"high": {}},
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
