"""間取り抽出の検証。

寸法が既知の合成部屋（直方体）を作り、床・天井・主方向・内法寸法を
正しく復元できるかを見る。実機データでは正解が分からないので、
ここで数学的な正しさを押さえておく。
"""

from __future__ import annotations

import numpy as np
import pytest

from mdr2colmap import floorplan
from mdr2colmap.mesh import Mesh, read_ply_mesh

ROOM_W, ROOM_D, ROOM_H = 3.0, 4.0, 2.4
FLOOR_Y = -1.0


def _quad(p0, p1, p2, p3, verts, faces):
    i = len(verts)
    verts.extend([p0, p1, p2, p3])
    faces.extend([[i, i + 1, i + 2], [i, i + 2, i + 3]])


def make_room(yaw_deg: float = 0.0, subdiv: int = 12) -> Mesh:
    """内向きの面を持つ直方体の部屋を作る。

    subdiv で面を細かく分割する。壁の面積重みが効く処理を通すため、
    1 枚の大きな四角形ではなく細かいメッシュにしておく。
    """
    verts: list[list[float]] = []
    faces: list[list[int]] = []
    x0, x1 = -ROOM_W / 2, ROOM_W / 2
    z0, z1 = -ROOM_D / 2, ROOM_D / 2
    y0, y1 = FLOOR_Y, FLOOR_Y + ROOM_H

    xs = np.linspace(x0, x1, subdiv)
    zs = np.linspace(z0, z1, subdiv)
    ys = np.linspace(y0, y1, subdiv)

    for a in range(subdiv - 1):
        for b in range(subdiv - 1):
            # 床と天井
            _quad([xs[a], y0, zs[b]], [xs[a+1], y0, zs[b]],
                  [xs[a+1], y0, zs[b+1]], [xs[a], y0, zs[b+1]], verts, faces)
            _quad([xs[a], y1, zs[b]], [xs[a], y1, zs[b+1]],
                  [xs[a+1], y1, zs[b+1]], [xs[a+1], y1, zs[b]], verts, faces)
            # z 一定の壁（法線が z 方向）
            _quad([xs[a], ys[b], z0], [xs[a+1], ys[b], z0],
                  [xs[a+1], ys[b+1], z0], [xs[a], ys[b+1], z0], verts, faces)
            _quad([xs[a], ys[b], z1], [xs[a], ys[b+1], z1],
                  [xs[a+1], ys[b+1], z1], [xs[a+1], ys[b], z1], verts, faces)
            # x 一定の壁（法線が x 方向）
            _quad([x0, ys[b], zs[a]], [x0, ys[b+1], zs[a]],
                  [x0, ys[b+1], zs[a+1]], [x0, ys[b], zs[a+1]], verts, faces)
            _quad([x1, ys[b], zs[a]], [x1, ys[b], zs[a+1]],
                  [x1, ys[b+1], zs[a+1]], [x1, ys[b+1], zs[a]], verts, faces)

    V = np.array(verts, float)
    if yaw_deg:
        a = np.radians(yaw_deg)
        c, s = np.cos(a), np.sin(a)
        R = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
        V = V @ R.T
    return Mesh(vertices=V, faces=np.array(faces, np.int64))


def test_detects_floor_and_ceiling():
    levels = floorplan.detect_levels(make_room())
    assert levels.floor == pytest.approx(FLOOR_Y, abs=0.05)
    assert levels.ceiling == pytest.approx(FLOOR_Y + ROOM_H, abs=0.05)
    assert levels.height == pytest.approx(ROOM_H, abs=0.08)


@pytest.mark.parametrize("yaw", [0.0, 20.0, 66.0, -35.0])
def test_recovers_interior_size_at_any_orientation(yaw: float):
    """部屋がどの向きに置かれていても内法寸法が出ること。

    実機データでは部屋が 66° 傾いていた。主方向の検出が効いていないと
    外接矩形が膨らんで寸法が過大になる。
    """
    plan = floorplan.extract(make_room(yaw_deg=yaw))
    inner = floorplan.interior_size(plan)
    assert inner is not None, f"yaw={yaw}: 軸ごとに壁が2枚取れませんでした"
    assert sorted(inner) == pytest.approx([ROOM_W, ROOM_D], abs=0.15)


def test_finds_four_walls():
    plan = floorplan.extract(make_room(yaw_deg=30.0))
    assert len(plan.walls) == 4
    assert sum(1 for w in plan.walls if w.axis == 0) == 2
    assert sum(1 for w in plan.walls if w.axis == 1) == 2


def test_svg_and_dxf_are_produced():
    plan = floorplan.extract(make_room())
    svg = floorplan.to_svg(plan)
    assert svg.startswith("<svg") and svg.rstrip().endswith("</svg>")
    dxf = floorplan.to_dxf(plan)
    assert dxf.startswith("0\nSECTION") and dxf.rstrip().endswith("EOF")
    assert "WALL" in dxf


def test_mesh_reader_roundtrip(tmp_path):
    """capture 側が書く形式の PLY を読めること。"""
    m = make_room()
    p = tmp_path / "m.ply"
    header = (
        "ply\nformat binary_little_endian 1.0\n"
        f"element vertex {len(m.vertices)}\n"
        "property float x\nproperty float y\nproperty float z\n"
        f"element face {len(m.faces)}\n"
        "property list uchar int vertex_indices\nend_header\n"
    )
    with p.open("wb") as fh:
        fh.write(header.encode("ascii"))
        fh.write(m.vertices.astype("<f4").tobytes())
        for f in m.faces:
            fh.write(bytes([3]) + f.astype("<i4").tobytes())

    got = read_ply_mesh(p)
    assert len(got.vertices) == len(m.vertices)
    assert len(got.faces) == len(m.faces)
    assert np.allclose(got.vertices, m.vertices, atol=1e-4)
