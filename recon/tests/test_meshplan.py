"""メッシュ由来の平面図。**静かに壊れる種類の処理**なので性質で押さえる。

壊れ方は 3 つ。どれも面積の数字だけ見ていると気づけない:

- 輪郭が軸平行でなくなる（格子から取っているのであり得ないはずのもの）
- 縦横が交互に並ばなくなる（短辺を潰す処理で図形が壊れる）
- 単純化で面積が大きく動く（潰しすぎ）
"""
import numpy as np
import pytest

from mdr2colmap import meshplan
from mdr2colmap.mesh import Mesh


def box_room(w=3.0, d=4.0, h=2.4, step=0.04):
    # **格子（5cm）より細かく刻む。** ARKit の実測は辺 30mm で、板が粗いと
    # 占有格子が埋まらず「撮り残し」と誤判定される。
    """壁・床・天井を持つ直方体の部屋。法線は内向きでなくてよい。"""
    verts, faces = [], []

    def quad(p0, p1, p2, p3):
        i = len(verts)
        verts.extend([p0, p1, p2, p3])
        faces.extend([[i, i + 1, i + 2], [i, i + 2, i + 3]])

    nx, nz = int(w / step), int(d / step)
    for i in range(nx):
        for j in range(nz):
            x0, x1 = i * step, (i + 1) * step
            z0, z1 = j * step, (j + 1) * step
            quad([x0, 0, z0], [x1, 0, z0], [x1, 0, z1], [x0, 0, z1])          # 床
            quad([x0, h, z0], [x1, h, z0], [x1, h, z1], [x0, h, z1])          # 天井
    ny = int(h / step)
    for i in range(nx):
        for k in range(ny):
            x0, x1 = i * step, (i + 1) * step
            y0, y1 = k * step, (k + 1) * step
            quad([x0, y0, 0], [x1, y0, 0], [x1, y1, 0], [x0, y1, 0])
            quad([x0, y0, d], [x1, y0, d], [x1, y1, d], [x0, y1, d])
    for j in range(nz):
        for k in range(ny):
            z0, z1 = j * step, (j + 1) * step
            y0, y1 = k * step, (k + 1) * step
            quad([0, y0, z0], [0, y0, z1], [0, y1, z1], [0, y1, z0])
            quad([w, y0, z0], [w, y0, z1], [w, y1, z1], [w, y1, z0])
    return Mesh(vertices=np.array(verts, float), faces=np.array(faces, np.int64))


def test_extracts_the_room():
    p = meshplan.extract(box_room(3.0, 4.0, 2.4))
    assert p is not None
    assert p.height == pytest.approx(2.4, abs=0.1)
    # 内法 12 m2。格子 5cm と半セル補正のぶんの誤差を見る。
    assert p.area == pytest.approx(12.0, rel=0.05)
    assert p.reliable


def test_outline_is_rectilinear_and_alternating():
    p = meshplan.extract(box_room(3.0, 4.0, 2.4))
    poly = p.outline
    n = len(poly)
    assert n >= 4
    for i in range(n):
        d = poly[(i + 1) % n] - poly[i]
        assert abs(d[0]) < 1e-9 or abs(d[1]) < 1e-9, "軸平行でない辺がある"
        e = poly[(i + 2) % n] - poly[(i + 1) % n]
        vert_a, vert_b = abs(d[0]) < 1e-9, abs(e[0]) < 1e-9
        assert vert_a != vert_b, "縦横が交互になっていない"


def test_simplify_is_stable_between_20_and_60cm():
    mesh = box_room(3.0, 4.0, 2.4)
    areas = [meshplan.extract(mesh, simplify=s).area for s in (0.2, 0.3, 0.45, 0.6)]
    assert max(areas) - min(areas) < 0.05, f"単純化で面積が動く: {areas}"


def test_partial_ceiling_is_flagged():
    """**天井の撮り残しで面積が外れる。** 実測で外れた 1 件がこの形だった
    （天井被覆 7.25 m² に対し面積 11.29）。焼いた後に自動で分かること。"""
    mesh = box_room(3.0, 4.0, 2.4)
    c = mesh.vertices[mesh.faces].mean(axis=1)
    drop = (c[:, 1] > 2.0) & (c[:, 2] > 1.5)       # 天井の半分を落とす
    p = meshplan.extract(Mesh(vertices=mesh.vertices, faces=mesh.faces[~drop]))
    assert p is not None
    assert not p.reliable


def test_missing_ceiling_is_flagged():
    """天井が 1 枚も無いと `levels` が床を天井としても拾う。階高で弾く。"""
    mesh = box_room(3.0, 4.0, 2.4)
    c = mesh.vertices[mesh.faces].mean(axis=1)
    p = meshplan.extract(Mesh(vertices=mesh.vertices, faces=mesh.faces[c[:, 1] <= 2.0]))
    assert p is None or not p.reliable


def test_polygon_area_of_a_unit_square():
    sq = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], float)
    assert abs(meshplan.polygon_area(sq)) == pytest.approx(1.0)


def test_drop_short_keeps_the_polygon_closed():
    # 1 辺に 5cm の段差がある長方形
    poly = np.array([[0, 0], [10, 0], [10, 5], [5, 5], [5, 5.1], [0, 5.1]], float)
    out = meshplan.drop_short(poly, 1.0)
    assert len(out) == 4
    assert abs(meshplan.polygon_area(out)) == pytest.approx(50, rel=0.05)


def test_empty_mesh_returns_none():
    assert meshplan.extract(Mesh(vertices=np.zeros((0, 3)), faces=np.zeros((0, 3), np.int64))) is None
