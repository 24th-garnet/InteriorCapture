"""RoomPlan の room.json 読み込みと間取り図生成のテスト。

実データで目視確認はしているが、それでは**間違っても気づけない性質の誤り**が
残る。特に:

- 列優先 / 行優先の取り違え（近似的に対称な行列では動いてしまう）
- 上方向を Y ではなく Z と思い込む（立面図になるが、正方形の部屋では気づきにくい）
- 開口部を親の壁に沿った 1 次元座標へ落とす計算

いずれも「それらしい図」が出てしまうので、既知の答えを持つ合成データで押さえる。
"""

from __future__ import annotations

import json
import math

import numpy as np
import pytest

from mdr2colmap import roomplan


def _column_major(rows: list[list[float]]) -> list[float]:
    """行で書いた 4x4 を、RoomPlan と同じ列優先の 16 要素にする。"""
    m = np.array(rows, float)
    return m.T.reshape(-1).tolist()


def _surface(center, x_axis, width, height, ident, parent=None, category="wall"):
    """1 枚の面を RoomPlan の JSON 表現で作る。

    列 0 = 幅方向、列 1 = 上（Y）、列 2 = 法線、列 3 = 中心。
    """
    x = np.array(x_axis, float)
    x /= np.linalg.norm(x)
    up = np.array([0.0, 1.0, 0.0])
    n = np.cross(x, up)
    n /= np.linalg.norm(n)
    T = [
        [x[0], up[0], n[0], center[0]],
        [x[1], up[1], n[1], center[1]],
        [x[2], up[2], n[2], center[2]],
        [0.0, 0.0, 0.0, 1.0],
    ]
    out = {
        "identifier": ident,
        "dimensions": [width, height, 0.0],
        "transform": _column_major(T),
        "category": {category: {}},
        "confidence": {"high": {}},
    }
    if parent is not None:
        out["parentIdentifier"] = parent
    return out


@pytest.fixture
def square_room(tmp_path):
    """4m x 3m、天井高 2.4m、床 Y=0 の部屋。

    壁の中心の Y は 1.2（床 0 + 高さ 2.4 の半分）。
    """
    h = 2.4
    cy = h / 2
    walls = [
        # X 方向に伸びる壁 2 枚（Z = 0 と Z = 3）
        _surface([2.0, cy, 0.0], [1, 0, 0], 4.0, h, "W-S"),
        _surface([2.0, cy, 3.0], [1, 0, 0], 4.0, h, "W-N"),
        # Z 方向に伸びる壁 2 枚（X = 0 と X = 4）
        _surface([0.0, cy, 1.5], [0, 0, 1], 3.0, h, "W-W"),
        _surface([4.0, cy, 1.5], [0, 0, 1], 3.0, h, "W-E"),
    ]
    # 南の壁（Z=0、X 0→4）の X=1.0〜1.8 にドア。中心 X=1.4
    door = _surface([1.4, 1.0, 0.0], [1, 0, 0], 0.8, 2.0, "D-1",
                    parent="W-S", category="door")
    data = {
        "walls": walls,
        "doors": [door],
        "windows": [],
        "openings": [],
        "floors": [],
        "objects": [],
    }
    p = tmp_path / "room.json"
    p.write_text(json.dumps(data))
    return p


def test_walls_become_xz_segments(square_room):
    """壁が X-Z 平面の線分になる。Y は落ちる。"""
    layout = roomplan.load(square_room)
    assert len(layout.walls) == 4
    for w in layout.walls:
        assert w.p0.shape == (2,)
        assert w.p1.shape == (2,)

    lengths = sorted(round(w.length, 3) for w in layout.walls)
    assert lengths == [3.0, 3.0, 4.0, 4.0]


def test_floor_and_ceiling_from_wall_extents(square_room):
    layout = roomplan.load(square_room)
    assert layout.floor_y == pytest.approx(0.0, abs=1e-6)
    assert layout.height == pytest.approx(2.4, abs=1e-6)


def test_area_uses_wall_polygon_not_bounding_box(square_room):
    """4x3 の部屋なので 12 m2。畳換算も確認する。"""
    layout = roomplan.load(square_room)
    assert layout.polygon is not None, "4 枚の壁は閉じるべき"
    assert layout.area == pytest.approx(12.0, abs=0.05)
    assert layout.tatami == pytest.approx(12.0 / 1.62, abs=0.05)


def test_opening_projects_onto_parent_wall(square_room):
    """ドアが親の壁に沿った区間として入る。

    南の壁は X=0 から X=4 へ伸び、ドアは中心 X=1.4 幅 0.8。
    壁の始点からの距離で 1.0〜1.8 になる。
    """
    layout = roomplan.load(square_room)
    south = next(w for w in layout.walls if w.identifier == "W-S")
    assert len(south.openings) == 1
    o = south.openings[0]
    assert o.category == "door"
    assert o.width == pytest.approx(0.8, abs=1e-3)
    assert min(o.start, o.end) == pytest.approx(1.0, abs=1e-3)
    assert max(o.start, o.end) == pytest.approx(1.8, abs=1e-3)
    # 他の壁には割り当てられていない
    assert sum(len(w.openings) for w in layout.walls) == 1


def test_solid_spans_exclude_the_opening(square_room):
    layout = roomplan.load(square_room)
    south = next(w for w in layout.walls if w.identifier == "W-S")
    spans = south.solid_spans
    assert len(spans) == 2
    assert spans[0] == pytest.approx((0.0, 1.0), abs=1e-3)
    assert spans[1] == pytest.approx((1.8, 4.0), abs=1e-3)
    # 実体部分の合計 = 壁長 - 開口幅
    total = sum(e - s for s, e in spans)
    assert total == pytest.approx(4.0 - 0.8, abs=1e-3)


def test_opening_snaps_to_nearest_wall_when_parent_is_wrong(square_room):
    """parentIdentifier が壊れていても、最も近い壁に割り当てる。

    親の id を信じて落とすと開口が図から消える。それは無言の欠落になるので、
    近傍への割り当てに落とす。
    """
    data = json.loads(square_room.read_text())
    data["doors"][0]["parentIdentifier"] = "存在しない壁"
    square_room.write_text(json.dumps(data))

    layout = roomplan.load(square_room)
    south = next(w for w in layout.walls if w.identifier == "W-S")
    assert len(south.openings) == 1


def test_column_major_transform_is_not_row_major(tmp_path):
    """列優先を行優先として読むと壁の向きが変わることを押さえる。

    近似的に対称な行列だと取り違えても「動いてしまう」ので、
    非対称な配置で明示的に確認する。
    """
    # X 方向に伸びる壁を、中心 (5, 1.2, 2) に置く
    s = _surface([5.0, 1.2, 2.0], [1, 0, 0], 2.0, 2.4, "W")
    data = {"walls": [s], "doors": [], "windows": [], "openings": [],
            "floors": [], "objects": []}
    p = tmp_path / "room.json"
    p.write_text(json.dumps(data))

    layout = roomplan.load(p)
    w = layout.walls[0]
    # 中心が (x=5, z=2) で、X 方向に ±1 伸びる
    mid = (w.p0 + w.p1) / 2
    assert mid == pytest.approx([5.0, 2.0], abs=1e-3)
    assert abs(w.direction[0]) == pytest.approx(1.0, abs=1e-3)
    assert abs(w.direction[1]) == pytest.approx(0.0, abs=1e-3)


def test_rotated_wall_keeps_its_direction(tmp_path):
    """斜めの壁も表現できる。Manhattan 前提の floorplan.py との差。"""
    s = _surface([0.0, 1.2, 0.0], [1, 0, 1], 2.0 * math.sqrt(2), 2.4, "W")
    data = {"walls": [s], "doors": [], "windows": [], "openings": [],
            "floors": [], "objects": []}
    p = tmp_path / "room.json"
    p.write_text(json.dumps(data))

    w = roomplan.load(p).walls[0]
    assert w.p0 == pytest.approx([-1.0, -1.0], abs=1e-3)
    assert w.p1 == pytest.approx([1.0, 1.0], abs=1e-3)


def test_svg_and_dxf_are_produced(square_room):
    layout = roomplan.load(square_room)
    svg = roomplan.to_svg(layout)
    assert svg.startswith("<svg")
    assert svg.rstrip().endswith("</svg>")
    # 面積・帖数・天井高が図に出る。面積は切り捨て表示で「約」を付ける
    assert "約 12.00 m²" in svg
    assert "約 7.4 帖" in svg          # 12.0 / 1.62 = 7.407... -> 切り捨て
    assert "2400 mm" in svg
    assert "内法実測" in svg
    # 但し書きが図の中に入る（別紙にすると図だけが流通する）
    assert "壁芯面積ではありません" in svg
    assert "販売対象ではありません" in svg
    assert "現況と異なる場合があります" in svg

    dxf = roomplan.to_dxf(layout)
    assert dxf.startswith("0\nSECTION")
    assert dxf.rstrip().endswith("EOF")
    assert "WALL" in dxf and "DOOR" in dxf


def test_open_walls_fall_back_to_bounding_box(tmp_path):
    """壁が閉じない場合は外接矩形で面積を出し、要約で断る。"""
    walls = [
        _surface([2.0, 1.2, 0.0], [1, 0, 0], 4.0, 2.4, "A"),
        _surface([2.0, 1.2, 3.0], [1, 0, 0], 4.0, 2.4, "B"),
    ]
    data = {"walls": walls, "doors": [], "windows": [], "openings": [],
            "floors": [], "objects": []}
    p = tmp_path / "room.json"
    p.write_text(json.dumps(data))

    layout = roomplan.load(p)
    assert layout.polygon is None
    assert layout.area == pytest.approx(12.0, abs=0.05)
    assert "外接矩形" in roomplan.summary(layout)


def test_area_display_never_overstates():
    """面積表示は小数第 2 位以下を切り捨てる。

    公正競争規約が禁じるのは実際より有利な誤認なので、切り上げ・四捨五入は
    使えない。11.288 を 11.29 と書くと実際より広い。
    """
    assert roomplan.display_area(11.288) == pytest.approx(11.28)
    assert roomplan.display_area(11.999) == pytest.approx(11.99)
    assert roomplan.display_area(12.0) == pytest.approx(12.0)


def test_tatami_display_keeps_one_mat_at_least_1_62():
    """帖数は切り捨てる。畳 1 枚が 1.62 m2 以上ある意味で使う定めのため。

    11.288 / 1.62 = 6.968... なので 6.9 帖。7.0 帖と書くと
    1 枚あたり 1.612 m2 になり 1.62 を下回る。
    """
    assert roomplan.display_tatami(11.288) == pytest.approx(6.9)
    assert 6.9 * roomplan.TATAMI_AREA <= 11.288
    assert 7.0 * roomplan.TATAMI_AREA > 11.288
    # ちょうど割り切れる場合は切り捨てても減らない
    assert roomplan.display_tatami(6 * 1.62) == pytest.approx(6.0)


def test_section_label_becomes_a_room_name(square_room):
    """RoomPlan の section から室名を取る。無ければ「居室」。"""
    data = json.loads(square_room.read_text())
    data["sections"] = [{"label": "bedroom", "center": [2.0, 1.0, 1.5], "story": 0}]
    square_room.write_text(json.dumps(data))
    layout = roomplan.load(square_room)
    assert layout.room_name == "洋室"
    assert "洋室" in roomplan.to_svg(layout)

    data["sections"] = []
    square_room.write_text(json.dumps(data))
    assert roomplan.load(square_room).room_name == "居室"


def test_floor_polygon_is_read_but_not_used_for_area(square_room):
    """`floors` の外形は照合用に読むが、面積そのものには使わない。

    実データでは壁からの内法 11.288 m2 と床の多角形 11.29 m2 が一致する。
    ここでは意図的に食い違う床を与えて、面積が壁側から出ることを押さえる。
    """
    data = json.loads(square_room.read_text())
    data["floors"] = [{
        "identifier": "F",
        "category": {"floor": {}},
        "confidence": {"high": {}},
        "dimensions": [5.0, 4.0, 0.0],
        "transform": _column_major([[1, 0, 0, 2.0], [0, 0, 1, 0.0],
                                    [0, -1, 0, 1.5], [0, 0, 0, 1]]),
        "polygonCorners": [[-2.5, -2.0, 0.0], [2.5, -2.0, 0.0],
                           [2.5, 2.0, 0.0], [-2.5, 2.0, 0.0]],
        "completedEdges": [],
        "curve": None,
    }]
    square_room.write_text(json.dumps(data))
    layout = roomplan.load(square_room)
    assert layout.floor_polygon is not None
    assert layout.floor_area == pytest.approx(20.0, abs=0.1)
    # 面積は壁からの内法のまま
    assert layout.area == pytest.approx(12.0, abs=0.05)
