"""メッシュだけから平面図の素を取り出す。**RoomPlan を使わない経路。**

`floorplan.py` は壁を線として拾うが、こちらは**内部を面として塗る**。
床が家具に隠れていても天井が見えていれば内法が出るので、面積が欠けない。

RoomPlan を持つ 5 バンドルで答え合わせした結果（同じ部屋、`room.json` の
壁ループ面積が基準）:

    room-428768ea  11.37 / 11.44  -0.6%    天井被覆 11.00
    room-3fc5c880  11.25 / 11.36  -1.0%    天井被覆 10.91
    room-20528316  11.09 / 11.25  -1.5%    天井被覆 10.69
    room-1890b2fc  10.89 / 11.21  -2.8%    天井被覆 10.80
    room-33d49373   9.73 / 11.29 -13.8%    天井被覆  7.25  ← 撮り残し

**天井が撮れていれば -0.6〜-2.8%。** 外れた 1 件は天井被覆が 7.25 m² しか
なく、焼いた後に自動で検出できる。5 件はすべて同じ部屋なので、これは
「1 室を 5 回撮った再現性」であって 5 室での一般性ではない。

補正を 1 つ入れている。格子は壁セルを内部から除くので周長 × セル/2 ぶん
小さく出る（補正前は -3.7〜-6.0%）。
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np
from scipy import ndimage

from .mesh import Mesh

#: 壁とみなす帯の下端（床から m）。**家具を避けるためのもの。**
#: 0.3 にするとベッドやソファの側面が壁として立ち上がる。
WALL_LOW = 1.2
#: 同、上端。天井際のモールを拾わない。
WALL_HIGH = 2.1
#: 占有格子の 1 セル（m）。
CELL = 0.05
#: 床・天井とみなす高さの許容（m）。
LEVEL_TOL = 0.12
#: 輪郭を単純化するときに潰す辺の長さ（m）。20〜60cm で結果が動かない。
SIMPLIFY = 0.30


@dataclass
class MeshPlan:
    """メッシュ由来の平面図。座標はすべて主方向で回した後の枠（m）。"""

    floor_y: float
    ceiling_y: float
    #: 主方向（度）。world から回した量。
    angle: float
    #: 壁面法線の集中度。1 に近いほど直交している。
    concentration: float
    #: 内法面積（半セル補正後、m²）。
    area: float
    #: 床が見えた面積 / 天井が見えた面積（撮り残しの検出用）。
    floor_seen: float
    ceiling_seen: float
    #: 輪郭（矩形折れ線、m）。
    outline: np.ndarray
    #: 内部マスクと格子の原点。
    mask: np.ndarray = field(repr=False)
    origin: tuple[float, float, float] = (0.0, 0.0, CELL)
    triangles: int = 0

    @property
    def height(self) -> float:
        return self.ceiling_y - self.floor_y

    @property
    def reliable(self) -> bool:
        """信じてよい平面図か。**外れるときは必ずここに出る。**

        条件は 2 つ。

        - **天井が十分に撮れている。** 床は家具に隠れるので、内部領域は
          天井で決まる。実測で外れた 1 件は天井被覆 7.25 m²（面積 11.29）
        - **階高が部屋として成り立つ。** 天井を 1 枚も撮っていないと
          `levels` が床を天井としても拾い、階高がほぼ 0 になる。この
          状態の面積は床の見えた範囲でしかない
        """
        return self.ceiling_seen >= self.area * 0.85 and self.height >= 1.8


def levels(centroids: np.ndarray, normals: np.ndarray, areas: np.ndarray,
           bin_m: float = 0.05) -> tuple[float, float]:
    """水平面の面積ヒストグラムから床と天井の高さを返す。"""
    horiz = np.abs(normals[:, 1]) > 0.9
    if not horiz.any():
        return float(centroids[:, 1].min()), float(centroids[:, 1].max())
    lo, hi = centroids[horiz, 1].min(), centroids[horiz, 1].max()
    bins = np.arange(lo - bin_m, hi + 2 * bin_m, bin_m)
    h, _ = np.histogram(centroids[horiz, 1], bins=bins, weights=areas[horiz])
    centers = bins[:-1] + bin_m / 2
    mid = (lo + hi) / 2
    low, up = centers < mid, centers >= mid
    if not low.any() or not up.any():
        return float(lo), float(hi)
    return float(centers[low][np.argmax(h[low])]), float(centers[up][np.argmax(h[up])])


def principal_angle(normals: np.ndarray, areas: np.ndarray,
                    sel: np.ndarray) -> tuple[float, float]:
    """壁面法線から主方向（ラジアン）と集中度を返す。90 度周期。"""
    th = np.arctan2(normals[sel, 2], normals[sel, 0])
    w = areas[sel]
    m = np.sum(w * np.exp(4j * th)) / w.sum()
    return float(np.angle(m) / 4), float(abs(m))


def rotation(angle_rad: float) -> np.ndarray:
    c, s = math.cos(-angle_rad), math.sin(-angle_rad)
    return np.array([[c, -s], [s, c]])


def extract(mesh: Mesh, wall_low: float = WALL_LOW, wall_high: float = WALL_HIGH,
            cell: float = CELL, simplify: float = SIMPLIFY) -> MeshPlan | None:
    """メッシュから内法面積と輪郭を求める。"""
    V, F = mesh.vertices, mesh.faces
    if len(F) < 10:
        return None
    tri = V[F]
    n = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    areas = 0.5 * np.linalg.norm(n, axis=1)
    n = n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
    c = tri.mean(axis=1)

    floor_y, ceil_y = levels(c, n, areas)
    wall = (np.abs(n[:, 1]) < 0.25) & (c[:, 1] > floor_y + wall_low) & (c[:, 1] < floor_y + wall_high)
    if wall.sum() < 50:
        return None
    ang, conc = principal_angle(n, areas, wall)

    R = rotation(ang)
    P = np.stack([c[:, 0], c[:, 2]], 1) @ R.T
    x0, x1 = P[:, 0].min() - 0.3, P[:, 0].max() + 0.3
    z0, z1 = P[:, 1].min() - 0.3, P[:, 1].max() + 0.3
    W, H = int((x1 - x0) / cell) + 1, int((z1 - z0) / cell) + 1

    def grid(sel: np.ndarray) -> np.ndarray:
        g = np.zeros((H, W))
        np.add.at(g, (((P[sel, 1] - z0) / cell).astype(int).clip(0, H - 1),
                      ((P[sel, 0] - x0) / cell).astype(int).clip(0, W - 1)), areas[sel])
        return g

    floor = (np.abs(n[:, 1]) > 0.85) & (np.abs(c[:, 1] - floor_y) < LEVEL_TOL)
    ceil = (np.abs(n[:, 1]) > 0.85) & (c[:, 1] > ceil_y - LEVEL_TOL)
    unit = cell * cell
    gf, gc, gw = grid(floor), grid(ceil), grid(wall)

    seen = (gf > unit * 0.2) | (gc > unit * 0.2)
    barrier = gw > unit * 0.3
    region = ndimage.binary_fill_holes(
        ndimage.binary_closing(seen & ~barrier, np.ones((5, 5))))
    lab, cnt = ndimage.label(region)
    if cnt == 0:
        return None
    sizes = ndimage.sum(region, lab, range(1, cnt + 1))
    mask = ndimage.binary_fill_holes(lab == (int(np.argmax(sizes)) + 1))

    poly = trace(mask)
    if poly is None:
        return None
    poly = drop_short(poly, simplify / cell)
    pts = np.stack([x0 + poly[:, 0] * cell, z0 + poly[:, 1] * cell], 1)
    # **半セルぶん外へ広げる。** 格子は壁セルを内部から除くので内法が小さく出る。
    pts = pts + np.sign(pts - pts.mean(axis=0)) * cell / 2

    return MeshPlan(
        floor_y=floor_y, ceiling_y=ceil_y,
        angle=math.degrees(ang), concentration=conc,
        area=float(abs(polygon_area(pts))),
        floor_seen=float((gf > unit * 0.2).sum() * unit),
        ceiling_seen=float((gc > unit * 0.2).sum() * unit),
        outline=pts, mask=mask, origin=(x0, z0, cell), triangles=len(F))


# --- 輪郭 -------------------------------------------------------------------
#
# 格子なので輪郭は必ず軸平行の折れ線になる。セルの辺をそのままたどれば
# 近似なしで取れる（marching squares も外部ライブラリも要らない）。


def trace(mask: np.ndarray) -> np.ndarray | None:
    """最大の外周ループをセル座標の頂点列で返す。内部が左に来る向き。"""
    H, W = mask.shape
    pad = np.zeros((H + 2, W + 2), bool)
    pad[1:-1, 1:-1] = mask
    edges: dict[tuple[int, int], tuple[int, int]] = {}
    for r in range(1, H + 1):
        for c in range(1, W + 1):
            if not pad[r, c]:
                continue
            x, y = c - 1, r - 1
            if not pad[r - 1, c]: edges[(x, y)] = (x + 1, y)
            if not pad[r, c + 1]: edges[(x + 1, y)] = (x + 1, y + 1)
            if not pad[r + 1, c]: edges[(x + 1, y + 1)] = (x, y + 1)
            if not pad[r, c - 1]: edges[(x, y + 1)] = (x, y)

    loops = []
    while edges:
        start = next(iter(edges))
        loop, p = [start], start
        while True:
            q = edges.pop(p, None)
            if q is None or q == start:
                break
            loop.append(q)
            p = q
        if len(loop) > 3:
            loops.append(np.array(loop, float))
    if not loops:
        return None
    return max(loops, key=lambda L: abs(polygon_area(L)))


def polygon_area(poly: np.ndarray) -> float:
    x, y = poly[:, 0], poly[:, 1]
    return 0.5 * float(np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y))


def merge_collinear(poly: np.ndarray) -> np.ndarray:
    out = []
    n = len(poly)
    for i in range(n):
        a, b, c = poly[i - 1], poly[i], poly[(i + 1) % n]
        u, v = b - a, c - b
        if abs(u[0] * v[1] - u[1] * v[0]) > 1e-9:   # numpy 2 は 2D cross を廃した
            out.append(b)
    return np.array(out) if out else poly


def drop_short(poly: np.ndarray, min_len: float) -> np.ndarray:
    """短い辺を潰す。**測量ではなく作図なので、5cm の段差は描かない。**

    矩形折れ線では辺が縦横と交互に並ぶので、短い辺を消すとその**両隣は
    平行**になる（直交と仮定して交点を取ろうとすると図形が壊れる）。
    長いほうの隣の直線に短いほうを寄せて、2 本を 1 本に繋ぐ。
    """
    poly = merge_collinear(poly)
    while len(poly) > 4:
        n = len(poly)
        seg = np.linalg.norm(np.roll(poly, -1, axis=0) - poly, axis=1)
        i = int(np.argmin(seg))
        if seg[i] >= min_len:
            break
        prev_i = (i - 1) % n
        nxt = (i + 1) % n
        axis = 1 if abs(poly[i][0] - poly[nxt][0]) < 1e-9 else 0
        target = poly[i][axis] if seg[prev_i] >= seg[nxt] else poly[nxt][axis]
        keep = [j for j in range(n) if j != i and j != nxt]
        out = poly[keep].copy()
        for j, orig in enumerate(keep):
            if orig == prev_i or orig == (i + 2) % n:
                out[j][axis] = target
        poly = merge_collinear(out)
    return poly
