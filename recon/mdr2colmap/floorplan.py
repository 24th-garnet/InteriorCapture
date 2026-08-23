"""メッシュから間取り（壁線・寸法・開口部）を抽出する。

madoriba の本題。Scaniverse は見た目の 3D キャプチャに強い一方で
構造化された間取り抽出は弱いので、ここが差別化点になる。

方針:
  1. 高さヒストグラムから床と天井を決める
  2. 壁面の法線方位から部屋の主方向を求める（Manhattan 仮定）
  3. 主方向に合わせて回転し、壁面を各軸に投影してピーク＝壁線を取る
  4. 壁線に沿って鉛直方向の被覆を見て、開口部（ドア・窓）を検出する

限界: 単一の直方体に近い部屋を想定している。L 字や斜め壁のある部屋では
壁線の抽出が不完全になる。複数部屋は RoomPlan の StructureBuilder が適する。
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .mesh import Mesh


@dataclass
class Levels:
    floor: float
    ceiling: float

    @property
    def height(self) -> float:
        return self.ceiling - self.floor


@dataclass
class WallLine:
    """回転後の座標系における 1 枚の壁。

    `axis` が 0 なら x = position の面（法線が x 方向）、1 なら y = position。
    """

    axis: int
    position: float
    extent: tuple[float, float]
    area: float
    openings: list[tuple[float, float]] = field(default_factory=list)

    @property
    def length(self) -> float:
        return self.extent[1] - self.extent[0]


@dataclass
class FloorPlan:
    levels: Levels
    #: 主方向の方位角（度）。この角度だけ回転すると壁が軸平行になる。
    azimuth_deg: float
    walls: list[WallLine]
    #: 回転後の座標系での部屋の外接矩形 (xmin, ymin, xmax, ymax)
    bounds: tuple[float, float, float, float]
    #: 回転前の world 座標に戻すための情報
    center: np.ndarray

    @property
    def size(self) -> tuple[float, float]:
        x0, y0, x1, y1 = self.bounds
        return (x1 - x0, y1 - y0)

    @property
    def footprint_area(self) -> float:
        w, d = self.size
        return w * d


def detect_levels(mesh: Mesh, bins: int = 200) -> Levels:
    """床と天井の高さを求める。

    水平面（床・天井）の面積を高さでヒストグラムにすると、床と天井が
    двумя大きなピークとして出る。壁や家具は分散するのでピークにならない。
    """
    horiz = mesh.horizontal_faces()
    if not horiz.any():
        y = mesh.vertices[:, 1]
        return Levels(float(np.percentile(y, 1)), float(np.percentile(y, 99)))

    h = mesh.face_centroids[horiz, 1]
    w = mesh.face_areas[horiz]
    hist, edges = np.histogram(h, bins=bins, weights=w)
    centers = 0.5 * (edges[:-1] + edges[1:])

    lower = centers < np.median(h)
    floor = float(centers[lower][np.argmax(hist[lower])]) if lower.any() else float(h.min())
    upper = ~lower
    ceiling = float(centers[upper][np.argmax(hist[upper])]) if upper.any() else float(h.max())
    return Levels(floor, ceiling)


def dominant_azimuth(mesh: Mesh) -> float:
    """壁の主方向（度、0〜90）。

    壁面法線の方位角を面積重みでヒストグラムにし、90 度周期に畳んでピークを取る。
    直交する 2 方向を同時に評価できる（Manhattan 仮定）。
    """
    wall = mesh.vertical_faces()
    if not wall.any():
        return 0.0
    n = mesh.face_normals[wall]
    az = np.degrees(np.arctan2(n[:, 2], n[:, 0])) % 180.0
    hist, _ = np.histogram(az, bins=180, range=(0, 180), weights=mesh.face_areas[wall])
    folded = hist[:90] + hist[90:]
    return float(np.argmax(folded))


def _rotation(azimuth_deg: float) -> np.ndarray:
    """world の (x, z) を主方向に合わせる 2x2 回転。"""
    a = np.radians(-azimuth_deg)
    c, s = np.cos(a), np.sin(a)
    return np.array([[c, -s], [s, c]])


def extract(
    mesh: Mesh,
    wall_band: tuple[float, float] = (0.9, 1.8),
    grid: float = 0.05,
    min_wall_area: float = 0.8,
    opening_min_width: float = 0.5,
) -> FloorPlan:
    """メッシュから間取りを抽出する。

    wall_band は床からの高さ範囲。窓の下端より上、鴨居より下を狙う。
    """
    levels = detect_levels(mesh)
    azimuth = dominant_azimuth(mesh)
    R = _rotation(azimuth)

    wall = mesh.vertical_faces()
    cen = mesh.face_centroids[wall]
    area = mesh.face_areas[wall]
    nrm = mesh.face_normals[wall]

    lo, hi = levels.floor + wall_band[0], levels.floor + wall_band[1]
    band = (cen[:, 1] >= lo) & (cen[:, 1] <= hi)

    xy = cen[:, [0, 2]] @ R.T
    center = xy.mean(axis=0)
    xy = xy - center
    n2 = nrm[:, [0, 2]] @ R.T

    bounds = (
        float(np.percentile(xy[band, 0], 0.5)),
        float(np.percentile(xy[band, 1], 0.5)),
        float(np.percentile(xy[band, 0], 99.5)),
        float(np.percentile(xy[band, 1], 99.5)),
    )

    walls: list[WallLine] = []
    for axis in (0, 1):
        # その軸に垂直な面だけ（法線が軸方向を向いているもの）
        aligned = band & (np.abs(n2[:, axis]) > 0.7)
        if not aligned.any():
            continue
        pos = xy[aligned, axis]
        other = xy[aligned, 1 - axis]
        w = area[aligned]

        edges = np.arange(pos.min() - grid, pos.max() + 2 * grid, grid)
        hist, _ = np.histogram(pos, bins=edges, weights=w)
        centers = 0.5 * (edges[:-1] + edges[1:])

        for i in _peaks(hist, min_value=min_wall_area):
            p = float(centers[i])
            sel = np.abs(pos - p) < grid * 2
            if sel.sum() < 3:
                continue
            span = (float(other[sel].min()), float(other[sel].max()))
            line = WallLine(axis=axis, position=p, extent=span, area=float(w[sel].sum()))
            line.openings = _find_openings(other[sel], span, grid, opening_min_width)
            walls.append(line)

    return FloorPlan(
        levels=levels, azimuth_deg=azimuth, walls=walls, bounds=bounds, center=center
    )


def _peaks(hist: np.ndarray, min_value: float, min_gap: int = 4) -> list[int]:
    """ヒストグラムの局所ピークを、値の大きい順に間引きながら拾う。"""
    order = np.argsort(hist)[::-1]
    chosen: list[int] = []
    for i in order:
        if hist[i] < min_value:
            break
        if all(abs(int(i) - c) >= min_gap for c in chosen):
            chosen.append(int(i))
    return sorted(chosen)


def _find_openings(
    coords: np.ndarray, span: tuple[float, float], grid: float, min_width: float
) -> list[tuple[float, float]]:
    """壁に沿った被覆の切れ目を開口部とみなす。

    注意: 「開口部」と「スキャンし損ねた箇所」を区別できない。
    撮影が不十分なだけの穴も開口部として出てくる。
    """
    if span[1] - span[0] < min_width:
        return []
    edges = np.arange(span[0], span[1] + grid, grid)
    if len(edges) < 3:
        return []
    occ = np.histogram(coords, bins=edges)[0] > 0

    gaps: list[tuple[float, float]] = []
    start = None
    for i, filled in enumerate(occ):
        if not filled and start is None:
            start = i
        elif filled and start is not None:
            if (i - start) * grid >= min_width:
                gaps.append((float(edges[start]), float(edges[i])))
            start = None
    if start is not None and (len(occ) - start) * grid >= min_width:
        gaps.append((float(edges[start]), float(edges[-1])))
    return gaps


# -- 出力 --------------------------------------------------------------------


def interior_size(plan: FloorPlan) -> tuple[float, float] | None:
    """向かい合う壁の間隔から内法寸法を出す。

    外接矩形は家具や外れ値に引っ張られるので、壁線が軸ごとに 2 枚以上
    取れている場合はこちらを使うほうが正確。
    """
    dims = []
    for axis in (0, 1):
        pos = sorted(w.position for w in plan.walls if w.axis == axis)
        if len(pos) < 2:
            return None
        dims.append(pos[-1] - pos[0])
    return (dims[0], dims[1])


def to_svg(plan: FloorPlan, scale: float = 100.0, margin: float = 60.0) -> str:
    """間取り図を SVG で描く。scale はメートルあたりのピクセル数。"""
    x0, y0, x1, y1 = plan.bounds
    pad = 0.3
    x0, y0, x1, y1 = x0 - pad, y0 - pad, x1 + pad, y1 + pad
    W = (x1 - x0) * scale + margin * 2
    H = (y1 - y0) * scale + margin * 2

    def sx(x: float) -> float:
        return margin + (x - x0) * scale

    def sy(y: float) -> float:
        return margin + (y1 - y) * scale   # SVG は下向きが +

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" height="{H:.0f}" '
        f'viewBox="0 0 {W:.0f} {H:.0f}">',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        '<g stroke="#e3e6ea" stroke-width="1">',
    ]
    for gx in np.arange(np.ceil(x0), x1, 1.0):
        out.append(f'<line x1="{sx(gx):.1f}" y1="{margin:.1f}" x2="{sx(gx):.1f}" y2="{H-margin:.1f}"/>')
    for gy in np.arange(np.ceil(y0), y1, 1.0):
        out.append(f'<line x1="{margin:.1f}" y1="{sy(gy):.1f}" x2="{W-margin:.1f}" y2="{sy(gy):.1f}"/>')
    out.append("</g>")

    for w in plan.walls:
        a, b = w.extent
        # 開口部で分割して描く
        cuts = sorted(w.openings)
        segs, cur = [], a
        for oa, ob in cuts:
            if oa > cur:
                segs.append((cur, oa))
            cur = max(cur, ob)
        if cur < b:
            segs.append((cur, b))

        for s, e in segs:
            if w.axis == 0:
                out.append(
                    f'<line x1="{sx(w.position):.1f}" y1="{sy(s):.1f}" '
                    f'x2="{sx(w.position):.1f}" y2="{sy(e):.1f}" '
                    f'stroke="#1b1f24" stroke-width="7" stroke-linecap="square"/>'
                )
            else:
                out.append(
                    f'<line x1="{sx(s):.1f}" y1="{sy(w.position):.1f}" '
                    f'x2="{sx(e):.1f}" y2="{sy(w.position):.1f}" '
                    f'stroke="#1b1f24" stroke-width="7" stroke-linecap="square"/>'
                )
        for oa, ob in cuts:
            if w.axis == 0:
                out.append(
                    f'<line x1="{sx(w.position):.1f}" y1="{sy(oa):.1f}" '
                    f'x2="{sx(w.position):.1f}" y2="{sy(ob):.1f}" '
                    f'stroke="#d9822b" stroke-width="7" stroke-dasharray="6 5"/>'
                )
            else:
                out.append(
                    f'<line x1="{sx(oa):.1f}" y1="{sy(w.position):.1f}" '
                    f'x2="{sx(ob):.1f}" y2="{sy(w.position):.1f}" '
                    f'stroke="#d9822b" stroke-width="7" stroke-dasharray="6 5"/>'
                )

    inner = interior_size(plan)
    area = inner[0] * inner[1] if inner else plan.footprint_area
    label = (
        f"{inner[0]:.2f} x {inner[1]:.2f} m" if inner
        else f"{plan.size[0]:.2f} x {plan.size[1]:.2f} m"
    )
    out += [
        f'<text x="{margin:.0f}" y="{margin-28:.0f}" font-family="system-ui,sans-serif" '
        f'font-size="20" fill="#1b1f24">{label}  /  {area:.1f} m2  /  {area/1.62:.1f} 畳</text>',
        f'<text x="{margin:.0f}" y="{margin-8:.0f}" font-family="system-ui,sans-serif" '
        f'font-size="14" fill="#6b7280">天井高 {plan.levels.height:.2f} m  '
        f'主方向 {plan.azimuth_deg:.0f}°  グリッド 1 m  '
        f'橙の破線 = 開口部の候補</text>',
        "</svg>",
    ]
    return "\n".join(out)


def to_dxf(plan: FloorPlan) -> str:
    """AutoCAD R12 相当の最小 DXF。単位はメートル。

    壁を WALL レイヤ、開口部候補を OPENING レイヤの LINE として書く。
    """
    lines = ["0", "SECTION", "2", "ENTITIES"]

    def emit(x1, y1, x2, y2, layer):
        lines.extend([
            "0", "LINE", "8", layer,
            "10", f"{x1:.4f}", "20", f"{y1:.4f}", "30", "0.0",
            "11", f"{x2:.4f}", "21", f"{y2:.4f}", "31", "0.0",
        ])

    for w in plan.walls:
        a, b = w.extent
        cuts = sorted(w.openings)
        segs, cur = [], a
        for oa, ob in cuts:
            if oa > cur:
                segs.append((cur, oa))
            cur = max(cur, ob)
        if cur < b:
            segs.append((cur, b))
        for s, e in segs:
            if w.axis == 0:
                emit(w.position, s, w.position, e, "WALL")
            else:
                emit(s, w.position, e, w.position, "WALL")
        for oa, ob in cuts:
            if w.axis == 0:
                emit(w.position, oa, w.position, ob, "OPENING")
            else:
                emit(oa, w.position, ob, w.position, "OPENING")

    lines.extend(["0", "ENDSEC", "0", "EOF"])
    return "\n".join(lines) + "\n"
