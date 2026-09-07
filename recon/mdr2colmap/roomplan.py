"""RoomPlan の出力（`room.json`）から間取り図を作る。

なぜ投影しないのか
-----------------
「真上から見下ろした画を平面に写す」という発想は自然だが、**RoomPlan の出力は
すでにパラメトリック**なので投影もラスタライズも要らない。壁 1 枚は::

    dimensions: [幅, 高さ, 0]
    transform:  4x4（列優先）— 列0 = 幅方向、列1 = 上方向、列3 = 中心

として与えられ、平面上の線分は直接求まる::

    中心 = transform[:3, 3] の (x, z)
    方向 = transform[:3, 0] の (x, z) を正規化
    線分 = 中心 ± 方向 × 幅/2

**上方向は Y。** ARKit も RoomPlan も Y-up なので、真上から見るとは
**Y を捨てて X-Z 平面に置く**こと。「Z 軸から見て XY 平面へ」だと立面図になる。

幾何を描画して線を拾い直すと、この構造（どの壁のどこに幅いくらの開口があるか）を
わざわざ捨てて復元する作業になる。

`floorplan.py` との関係
----------------------
`floorplan.py` は LiDAR メッシュから壁を推定する別経路で、`WallLine` が
軸平行（`axis` + `position`）の Manhattan 前提。RoomPlan の壁は任意方向なので
表現できない。こちらは一般の線分として扱う。

メッシュ経路は 1 回の撮影で済む利点があるが、開口部の検出が発見的で不確実。
RoomPlan はドア・窓を型付きで返すため、不動産の間取り図としては優位。
実測（`room-33d49373`）では自前抽出と同じ 4 枚の壁を検出し、加えてドア 3 枚を得た。

座標系
-----
MDR 撮影と同じ `ARSession` 上で RoomPlan を走らせているので、
**この座標はメッシュや station と同じ ARKit world 座標**。実測で床の高さが
メッシュ -1.621 に対し RoomPlan -1.654（差 3.4cm）で一致を確認済み。
位置合わせは要らない。
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

#: 開口部を親の壁に割り当てる際の許容距離。これを超える距離にある開口は、
#: parentIdentifier が指す壁の線分から外れているとみなして落とす。
OPENING_SNAP_TOLERANCE = 0.35
#: 畳 1 枚あたりの面積 1.62 m2。
#:
#: 「不動産の表示に関する公正競争規約」施行規則の定めで、居室の広さを畳数で
#: 表示する場合は**畳 1 枚が 1.62 m2 以上ある**という意味で用いる。したがって
#: 帖数は切り捨てなければならない（切り上げると 1 枚が 1.62 m2 を下回る）。
TATAMI_AREA = 1.62

#: RoomPlan の section ラベルを販売図面の室名にする。
#:
#: 洋室 / 和室 の区別は床仕上げで決まるが RoomPlan は返さないので、
#: `bedroom` は一律「洋室」にする。畳敷きなら人が直す。
SECTION_JA = {
    "bedroom": "洋室", "livingRoom": "リビング", "diningRoom": "ダイニング",
    "kitchen": "キッチン", "bathroom": "浴室", "office": "書斎",
    "familyRoom": "居間", "storage": "納戸", "hallway": "廊下",
    "laundryRoom": "洗濯室", "diningArea": "ダイニング", "livingArea": "リビング",
}

#: 図の書体。**環境依存にしない。** Hiragino だけ指定すると Mac 以外で
#: 日本語が豆腐になり、但し書きが読めない図が流通する。
FONT_STACK = ("Hiragino Sans, Hiragino Kaku Gothic ProN, Yu Gothic, "
              "Noto Sans JP, Meiryo, sans-serif")

#: 図に入れる但し書き。公正競争規約が禁じるのは実際より有利な誤認なので、
#: **測っていないことと、測り方を必ず書く。**
DISCLAIMERS = (
    "面積は LiDAR による内法（うちのり）実測値です。壁芯面積ではありません。",
    f"帖数は 1 帖 = {TATAMI_AREA} m2 として換算し、小数第 1 位以下を切り捨てています。",
    "寸法は実測値のため誤差を含みます。契約時は実測図・登記簿を優先してください。",
    "記載の家具・什器は現況を示すもので、販売対象ではありません。",
    "扉の開き勝手および方位は未計測のため、図では表現していません。",
    "本図は現況と異なる場合があります。",
)


@dataclass
class Opening:
    """壁に空いた穴。ドア・窓・単なる開口。"""

    category: str
    #: 親の壁に沿った位置（メートル）。壁の始点からの距離。
    start: float
    end: float
    height: float
    #: 開口の下端の高さ（床からの高さ）。窓とドアの区別に使える。
    sill: float
    confidence: str

    @property
    def width(self) -> float:
        return self.end - self.start


@dataclass
class Wall:
    identifier: str
    #: 平面上の線分（X, Z）。
    p0: np.ndarray
    p1: np.ndarray
    height: float
    confidence: str
    openings: list[Opening] = field(default_factory=list)

    @property
    def length(self) -> float:
        return float(np.linalg.norm(self.p1 - self.p0))

    @property
    def direction(self) -> np.ndarray:
        d = self.p1 - self.p0
        n = np.linalg.norm(d)
        return d / n if n > 1e-9 else np.array([1.0, 0.0])

    def at(self, t: float) -> np.ndarray:
        """始点から距離 t の位置。"""
        return self.p0 + self.direction * t

    @property
    def solid_spans(self) -> list[tuple[float, float]]:
        """開口を除いた実体部分。描画で壁を切るのに使う。"""
        spans: list[tuple[float, float]] = []
        cursor = 0.0
        for o in sorted(self.openings, key=lambda x: x.start):
            a = max(0.0, min(o.start, self.length))
            b = max(0.0, min(o.end, self.length))
            if a > cursor:
                spans.append((cursor, a))
            cursor = max(cursor, b)
        if cursor < self.length:
            spans.append((cursor, self.length))
        return spans


@dataclass
class Section:
    """RoomPlan が返す室の区画。室名の出所。"""

    label: str
    #: 平面上の中心（X, Z）。
    center: np.ndarray

    @property
    def name(self) -> str:
        return SECTION_JA.get(self.label, self.label)


def display_area(m2: float) -> float:
    """公正競争規約に合わせた面積表示。**小数第 2 位以下を切り捨てる。**

    切り上げ・四捨五入は実際より広く見せることになるので使えない。
    """
    return math.floor(float(m2) * 100) / 100


def display_tatami(m2: float) -> float:
    """帖数表示。**小数第 1 位以下を切り捨てる。**

    畳 1 枚が 1.62 m2 以上あるという意味で用いる定めなので、
    切り上げると規約に反する。
    """
    return math.floor(float(m2) / TATAMI_AREA * 10) / 10


@dataclass
class Furniture:
    category: str
    #: 平面上の外形（4 隅、X-Z）。回転を保つため矩形は 4 点で持つ。
    corners: np.ndarray
    height: float


@dataclass
class RoomLayout:
    walls: list[Wall]
    furniture: list[Furniture]
    floor_y: float
    ceiling_y: float
    sections: list[Section] = field(default_factory=list)
    #: RoomPlan の `floors` が返す床の外形（X-Z）。壁が閉じないときの代替。
    floor_polygon: np.ndarray | None = None

    @property
    def room_name(self) -> str:
        """室名。区画が複数あるときは連結する。取れなければ「居室」。"""
        names = [s.name for s in self.sections]
        return "・".join(names) if names else "居室"

    @property
    def floor_area(self) -> float | None:
        """RoomPlan の床外形（`polygonCorners`）の面積。

        **壁の照合には使えない。** 実データで床の多角形の隅は壁ループの隅と
        完全に一致し（距離 0.0m、面積差 1.3e-6 m2）、壁の直線の交点とも一致した。
        RoomPlan は床を壁から導出しているので、突き合わせても何も検出できない。

        価値があるのは**壁が閉じなかったときの代替**。壁の連結が切れると
        `polygon` は None になり、外接矩形で代用すると過大表示になる。
        床の多角形があればそちらを使う。

        **`floors[].dimensions` は使わない。** 同じ床で 3.678 x 3.262 = 11.998 m2
        と出るが、これは多角形の実寸（3.601 x 3.135）より大きい外接的な値で、
        販売図面に使うと過大表示になる。
        """
        if self.floor_polygon is None:
            return None
        return _poly_area(self.floor_polygon)

    @property
    def height(self) -> float:
        return self.ceiling_y - self.floor_y

    @property
    def bounds(self) -> tuple[float, float, float, float]:
        pts = np.vstack([np.vstack([w.p0, w.p1]) for w in self.walls])
        return float(pts[:, 0].min()), float(pts[:, 1].min()), \
            float(pts[:, 0].max()), float(pts[:, 1].max())

    @property
    def polygon(self) -> np.ndarray | None:
        """壁を繋いだ閉多角形。閉じなければ None。

        壁は順序不定で返るので、端点が近いものを辿って並べ直す。
        L 字や凹んだ部屋でも、壁が繋がっていれば閉じる。
        """
        if len(self.walls) < 3:
            return None
        remaining = list(self.walls)
        first = remaining.pop(0)
        chain = [first.p0.copy(), first.p1.copy()]
        # 端点の一致判定。RoomPlan の壁は端点がぴったり合わないので緩める。
        tol = 0.35
        while remaining:
            tail = chain[-1]
            best, best_d, flip = None, tol, False
            for w in remaining:
                for pt, other, fl in ((w.p0, w.p1, False), (w.p1, w.p0, True)):
                    d = float(np.linalg.norm(pt - tail))
                    if d < best_d:
                        best, best_d, flip = w, d, fl
            if best is None:
                return None
            remaining.remove(best)
            chain.append((best.p0 if flip else best.p1).copy())
        # 始点に戻っていれば閉じている
        if float(np.linalg.norm(chain[-1] - chain[0])) > tol:
            return None
        return np.array(chain[:-1])

    @property
    def area_source(self) -> str:
        """面積の出所。`"壁"` / `"床外形"` / `"外接矩形"`。

        外接矩形は**必ず過大**になるので、販売図面ではその旨を明示する。
        """
        if self.polygon is not None:
            return "壁"
        if self.floor_polygon is not None:
            return "床外形"
        return "外接矩形"

    @property
    def area(self) -> float:
        """内法面積。

        壁のループが閉じればそれを使う。閉じない場合は RoomPlan の床外形を
        使い、それも無ければ外接矩形で代用する。**外接矩形は過大になる**ので
        最後の手段。
        """
        poly = self.polygon
        if poly is None:
            poly = self.floor_polygon
        if poly is None:
            x0, y0, x1, y1 = self.bounds
            return (x1 - x0) * (y1 - y0)
        return _poly_area(poly)

    @property
    def tatami(self) -> float:
        return self.area / TATAMI_AREA

    def openings(self, category: str | None = None) -> list[Opening]:
        out = [o for w in self.walls for o in w.openings]
        return [o for o in out if category is None or o.category == category]


# --- 読み込み ---------------------------------------------------------------


def _mat(values: list[float]) -> np.ndarray:
    """列優先の 16 要素を 4x4 にする。

    `reshape(4,4)` だけでは行優先として読んでしまう。転置が要る。
    近似的に対称な行列でも「動いてしまう」ので、間違いが表に出にくい。
    """
    return np.array(values, float).reshape(4, 4).T


def _category(value) -> str:
    """`{"wall": {}}` のような表現からカテゴリ名を取る。"""
    if isinstance(value, dict):
        return next(iter(value), "unknown")
    return str(value)


def _segment(surface: dict) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """面を平面上の線分にする。戻り値は (始点, 終点, 中心3D)。"""
    T = _mat(surface["transform"])
    center = T[:3, 3]
    x_axis = T[:3, 0]
    d = np.array([x_axis[0], x_axis[2]], float)
    n = np.linalg.norm(d)
    d = d / n if n > 1e-9 else np.array([1.0, 0.0])
    half = float(surface["dimensions"][0]) / 2
    c2 = np.array([center[0], center[2]], float)
    return c2 - d * half, c2 + d * half, center


def load(path: str | Path) -> RoomLayout:
    """`room.json` を読む。"""
    data = json.loads(Path(path).read_text())

    walls: list[Wall] = []
    for w in data.get("walls", []):
        p0, p1, center = _segment(w)
        walls.append(Wall(
            identifier=str(w["identifier"]),
            p0=p0, p1=p1,
            height=float(w["dimensions"][1]),
            confidence=_category(w.get("confidence")),
        ))

    by_id = {w.identifier: w for w in walls}
    floor_candidates = [
        _mat(w["transform"])[1, 3] - float(w["dimensions"][1]) / 2
        for w in data.get("walls", [])
    ]
    floor_y = float(np.median(floor_candidates)) if floor_candidates else 0.0

    # 開口部を親の壁に割り当てる。
    #
    # parentIdentifier があるのでそれを使うが、指す壁が無い/合わない場合も
    # あるので、最も近い壁への割り当てに落とす。落とさないと開口が消える。
    for key in ("doors", "windows", "openings"):
        for s in data.get(key, []):
            p0, p1, center = _segment(s)
            mid = (p0 + p1) / 2
            parent = by_id.get(str(s.get("parentIdentifier")))
            if parent is None or _distance_to(parent, mid) > OPENING_SNAP_TOLERANCE:
                parent = _nearest_wall(walls, mid)
            if parent is None:
                continue
            t0 = _project(parent, p0)
            t1 = _project(parent, p1)
            lo, hi = sorted((t0, t1))
            h = float(s["dimensions"][1])
            parent.openings.append(Opening(
                category=_category(s.get("category")) if key != "openings" else "opening",
                start=lo, end=hi,
                height=h,
                sill=float(center[1]) - h / 2 - floor_y,
                confidence=_category(s.get("confidence")),
            ))

    sections = [
        Section(label=str(sec.get("label", "")),
                center=np.array([float(sec["center"][0]), float(sec["center"][2])]))
        for sec in data.get("sections", [])
        if isinstance(sec.get("center"), list) and len(sec["center"]) >= 3
    ]

    floor_polygon = None
    floors = data.get("floors") or []
    if floors and floors[0].get("polygonCorners"):
        T = _mat(floors[0]["transform"])
        corners = np.array(floors[0]["polygonCorners"], float)
        if corners.shape[1] == 3:
            world = corners @ T[:3, :3].T + T[:3, 3]
            floor_polygon = world[:, [0, 2]]

    furniture: list[Furniture] = []
    for o in data.get("objects", []):
        T = _mat(o["transform"])
        c = T[:3, 3]
        wx, _hy, dz = (float(v) for v in o["dimensions"])
        ax = np.array([T[0, 0], T[2, 0]], float)
        az = np.array([T[0, 2], T[2, 2]], float)
        for v in (ax, az):
            n = np.linalg.norm(v)
            if n > 1e-9:
                v /= n
        c2 = np.array([c[0], c[2]], float)
        hw, hd = wx / 2, dz / 2
        furniture.append(Furniture(
            category=_category(o.get("category")),
            corners=np.array([
                c2 - ax * hw - az * hd, c2 + ax * hw - az * hd,
                c2 + ax * hw + az * hd, c2 - ax * hw + az * hd,
            ]),
            height=float(o["dimensions"][1]),
        ))

    ceiling = floor_y + (max((w.height for w in walls), default=0.0))
    return RoomLayout(walls=walls, furniture=furniture,
                      floor_y=floor_y, ceiling_y=ceiling,
                      sections=sections, floor_polygon=floor_polygon)


def _project(wall: Wall, point: np.ndarray) -> float:
    """壁の始点を 0 とした 1 次元座標へ落とす。"""
    return float(np.dot(point - wall.p0, wall.direction))


def _distance_to(wall: Wall, point: np.ndarray) -> float:
    """線分への距離。端の外側は端点までの距離。"""
    t = _project(wall, point)
    t = max(0.0, min(t, wall.length))
    return float(np.linalg.norm(point - wall.at(t)))


def _nearest_wall(walls: list[Wall], point: np.ndarray) -> Wall | None:
    if not walls:
        return None
    return min(walls, key=lambda w: _distance_to(w, point))


# --- 描画 -------------------------------------------------------------------

#: 壁の描画太さ（メートル）。実際の壁厚ではなく製図上の線幅。
WALL_THICKNESS = 0.09
#: これを超える幅の開口は両開きとして描く。片開きで描くと扉 1 枚が開口幅ぶん
#: 室内へ張り出し、図が読めなくなる。実測で 1736mm の開口があった。
DOUBLE_DOOR_WIDTH = 1.2
#: 家具のカテゴリ名を日本語に。間取り図に英語が混じると資料として使いにくい。
FURNITURE_JA = {
    "storage": "収納", "table": "テーブル", "chair": "椅子", "bed": "ベッド",
    "sofa": "ソファ", "television": "テレビ", "refrigerator": "冷蔵庫",
    "stove": "コンロ", "sink": "流し", "toilet": "便器", "bathtub": "浴槽",
    "washerDryer": "洗濯機", "oven": "オーブン", "dishwasher": "食洗機",
    "fireplace": "暖炉", "stairs": "階段", "screen": "スクリーン",
}


def _poly_area(corners: np.ndarray) -> float:
    x, y = corners[:, 0], corners[:, 1]
    return float(abs(np.dot(x, np.roll(y, -1)) - np.dot(np.roll(x, -1), y)) / 2)


def to_svg(layout: RoomLayout, scale: float = 110.0, margin: float = 104.0,
           show_furniture: bool = True) -> str:
    """間取り図を SVG で描く。`scale` はメートルあたりのピクセル数。

    製図の慣習に従う:
      - 壁は太い実線。開口部では途切れる
      - ドアは開口を弧で示す（開き勝手は RoomPlan から取れないので一律）
      - 窓は二重線
      - 各壁に寸法を添える
    """
    x0, y0, x1, y1 = layout.bounds
    pad = 0.55
    x0, y0, x1, y1 = x0 - pad, y0 - pad, x1 + pad, y1 + pad
    W = (x1 - x0) * scale + margin * 2
    # 下側は但し書きを入れるので広く取る
    notes_h = 30 + len(DISCLAIMERS) * 15
    H = (y1 - y0) * scale + margin * 2 + notes_h

    def px(p) -> tuple[float, float]:
        """world (X, Z) を画面座標へ。

        **+Z は画面下。反転してはいけない。** 真上（+Y 側）から見下ろす
        右手系では、画面右を +X に取ると画面上は -Z になる
        （X × (-Z) = +Y = 視点方向）。+Z を上にすると鏡像の間取り図になり、
        3D モデルと見比べたときにドアが逆側に出る。
        """
        return margin + (float(p[0]) - x0) * scale, margin + (float(p[1]) - y0) * scale

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" height="{H:.0f}" '
        f'viewBox="0 0 {W:.0f} {H:.0f}" font-family="{FONT_STACK}">',
        '<rect width="100%" height="100%" fill="#fdfdfb"/>',
    ]

    # 床（部屋の内側）を薄く塗る。範囲が一目で分かる。
    poly = layout.polygon
    if poly is not None:
        pts = " ".join(f"{a:.1f},{b:.1f}" for a, b in (px(p) for p in poly))
        out.append(f'<polygon points="{pts}" fill="#f2efe9" stroke="none"/>')

    if show_furniture:
        out.append('<g stroke="#b9b2a6" stroke-width="1.2" fill="#e8e3d9" fill-opacity="0.55">')
        for f in layout.furniture:
            pts = " ".join(f"{a:.1f},{b:.1f}" for a, b in (px(p) for p in f.corners))
            out.append(f'<polygon points="{pts}"/>')
        out.append("</g>")
        # ラベルは重なると読めなくなる。既に置いた位置から離れているものだけ出す。
        out.append('<g font-size="10" fill="#8a8275" text-anchor="middle">')
        placed: list[tuple[float, float]] = []
        for f in sorted(layout.furniture, key=lambda x: -_poly_area(x.corners)):
            cx, cy = px(f.corners.mean(axis=0))
            if any(abs(cx - a) < 46 and abs(cy - b) < 15 for a, b in placed):
                continue
            placed.append((cx, cy))
            name = FURNITURE_JA.get(f.category, f.category)
            out.append(f'<text x="{cx:.1f}" y="{cy + 3:.1f}">{name}</text>')
        out.append("</g>")

    thick = WALL_THICKNESS * scale
    out.append(f'<g stroke="#1a1d21" stroke-width="{thick:.1f}" stroke-linecap="butt">')
    for w in layout.walls:
        for s, e in w.solid_spans:
            if e - s < 0.02:
                continue
            ax, ay = px(w.at(s))
            bx, by = px(w.at(e))
            out.append(f'<line x1="{ax:.1f}" y1="{ay:.1f}" x2="{bx:.1f}" y2="{by:.1f}"/>')
    out.append("</g>")

    # 開口部の記号。室内側を決めるのに部屋の中心が要る。
    center = np.array([(x0 + x1) / 2, (y0 + y1) / 2])
    for w in layout.walls:
        d = w.direction
        normal = np.array([-d[1], d[0]])
        for o in w.openings:
            a = w.at(o.start)
            b = w.at(o.end)
            ax, ay = px(a)
            bx, by = px(b)
            if o.category == "window":
                # 窓は二重線。壁の芯から左右に少しずらす。
                for off in (-0.022, 0.022):
                    p, q = a + normal * off, b + normal * off
                    pxa, pya = px(p)
                    pxb, pyb = px(q)
                    out.append(f'<line x1="{pxa:.1f}" y1="{pya:.1f}" x2="{pxb:.1f}" '
                               f'y2="{pyb:.1f}" stroke="#1a1d21" stroke-width="2"/>')
            else:
                # ドア・開口は薄い線で塞ぎ、ドアなら開き弧を添える。
                out.append(f'<line x1="{ax:.1f}" y1="{ay:.1f}" x2="{bx:.1f}" y2="{by:.1f}" '
                           f'stroke="#cfc9bd" stroke-width="{thick:.1f}"/>')
                if o.category == "door":
                    inward = normal if np.dot(normal, center - (a + b) / 2) > 0 else -normal
                    # **広い開口は両開きとして描く。** 片開きで描くと扉 1 枚が
                    # 開口幅ぶん室内へ伸び、1736mm では部屋を横断して図が読めなくなる。
                    # 実際にもこの幅は引き違いや両開きで、片開きではない。
                    if o.width > DOUBLE_DOOR_WIDTH:
                        halves = [(a, o.width / 2, 1), (b, o.width / 2, -1)]
                    else:
                        halves = [(a, o.width, 1)]
                    for hinge, leaf, _side in halves:
                        leaf_end = hinge + inward * leaf
                        hx, hy = px(hinge)
                        lx, ly = px(leaf_end)
                        # 弧の終点は開口の中央（両開き）か反対端（片開き）。
                        far = (a + b) / 2 if len(halves) == 2 else b
                        fx, fy = px(far)
                        r = leaf * scale
                        out.append(
                            f'<line x1="{hx:.1f}" y1="{hy:.1f}" x2="{lx:.1f}" y2="{ly:.1f}" '
                            f'stroke="#1a1d21" stroke-width="1.8"/>'
                        )
                        # SVG は Y 下向きなので、掃く向きは 2 点の外積で決める。
                        v1 = np.array([lx - hx, ly - hy])
                        v2 = np.array([fx - hx, fy - hy])
                        sweep = 1 if (v1[0] * v2[1] - v1[1] * v2[0]) > 0 else 0
                        out.append(
                            f'<path d="M {lx:.1f} {ly:.1f} A {r:.1f} {r:.1f} 0 0 {sweep} '
                            f'{fx:.1f} {fy:.1f}" stroke="#9a9384" stroke-width="1.1" '
                            f'fill="none" stroke-dasharray="5 4"/>'
                        )

    # 寸法線。壁の外側にずらして引く。
    out.append('<g font-size="12" fill="#3a3f46" text-anchor="middle">')
    for w in layout.walls:
        d = w.direction
        normal = np.array([-d[1], d[0]])
        mid = (w.p0 + w.p1) / 2
        # 部屋の外を向く側へ出す
        if np.dot(mid - center, normal) < 0:
            normal = -normal
        off = normal * 0.26
        a1, a2 = px(w.p0 + off), px(w.p1 + off)
        out.append(f'<line x1="{a1[0]:.1f}" y1="{a1[1]:.1f}" x2="{a2[0]:.1f}" '
                   f'y2="{a2[1]:.1f}" stroke="#9aa1a9" stroke-width="1"/>')
        for p in (w.p0, w.p1):
            s, e = px(p + normal * 0.10), px(p + normal * 0.34)
            out.append(f'<line x1="{s[0]:.1f}" y1="{s[1]:.1f}" x2="{e[0]:.1f}" '
                       f'y2="{e[1]:.1f}" stroke="#9aa1a9" stroke-width="1"/>')
        tx, ty = px(mid + normal * 0.42)
        out.append(f'<text x="{tx:.1f}" y="{ty:.1f}">{w.length * 1000:.0f}</text>')
    out.append("</g>")

    # 室名と帖数。販売図面の慣例で室の中央に置く。
    area = display_area(layout.area)
    tatami = display_tatami(layout.area)
    poly = layout.polygon
    seat = (poly.mean(axis=0) if poly is not None
            else np.array([(x0 + x1) / 2, (y0 + y1) / 2]))
    if layout.sections:
        seat = layout.sections[0].center
    rx, ry = px(seat)
    out.append(
        f'<g text-anchor="middle" fill="#1a1d21">'
        f'<text x="{rx:.1f}" y="{ry - 4:.1f}" font-size="19" font-weight="600">'
        f'{layout.room_name}</text>'
        f'<text x="{rx:.1f}" y="{ry + 18:.1f}" font-size="16">約 {tatami:.1f} 帖</text>'
        f'</g>'
    )

    # 表題。面積は内法であることを面積のすぐ隣に書く。
    doors = len(layout.openings("door"))
    windows = len(layout.openings("window"))
    out.append(
        f'<g font-size="13" fill="#1a1d21">'
        f'<text x="{margin:.0f}" y="{margin - 46:.0f}" font-size="17" font-weight="600">'
        f'{layout.room_name}　約 {area:.2f} m²（約 {tatami:.1f} 帖）</text>'
        f'<text x="{margin:.0f}" y="{margin - 26:.0f}" fill="#5c6470">'
        f'内法実測　天井高 {layout.height * 1000:.0f} mm　'
        f'ドア {doors}　窓 {windows}　寸法 mm</text>'
        f'</g>'
    )

    # 但し書き。規約が禁じるのは実際より有利な誤認なので、測り方と
    # 測っていないものを図の中に置く。別紙にすると図だけが流通する。
    out.append(f'<g font-size="10.5" fill="#6b7280">')
    base = H - notes_h + 14
    for i, text in enumerate(DISCLAIMERS):
        out.append(f'<text x="{margin:.0f}" y="{base + i * 15:.0f}">※ {text}</text>')
    out.append("</g>")
    out.append("</svg>")
    return "\n".join(out)


def to_dxf(layout: RoomLayout) -> str:
    """CAD 向けに DXF（R12 相当の最小構成）で出す。

    レイヤを分ける: WALL / DOOR / WINDOW / OPENING / FURNITURE。
    設計事務所へ渡すときに要素ごとに扱えるようにする。
    """
    out = ["0", "SECTION", "2", "ENTITIES"]

    def line(p0, p1, layer: str) -> None:
        out.extend([
            "0", "LINE", "8", layer,
            "10", f"{float(p0[0]):.4f}", "20", f"{float(p0[1]):.4f}", "30", "0.0",
            "11", f"{float(p1[0]):.4f}", "21", f"{float(p1[1]):.4f}", "31", "0.0",
        ])

    for w in layout.walls:
        for s, e in w.solid_spans:
            if e - s >= 0.02:
                line(w.at(s), w.at(e), "WALL")
        for o in w.openings:
            layer = {"door": "DOOR", "window": "WINDOW"}.get(o.category, "OPENING")
            line(w.at(o.start), w.at(o.end), layer)

    for f in layout.furniture:
        for i in range(4):
            line(f.corners[i], f.corners[(i + 1) % 4], "FURNITURE")

    out.extend(["0", "ENDSEC", "0", "EOF"])
    return "\n".join(out)


def summary(layout: RoomLayout) -> str:
    """人が読む要約。CLI で出す。"""
    lines = [
        f"{layout.room_name}  約 {display_area(layout.area):.2f} m2"
        f"（約 {display_tatami(layout.area):.1f} 帖）内法実測"
        f"   天井高 {layout.height:.2f} m   床 Y={layout.floor_y:+.2f}",
    ]
    if layout.area_source != "壁":
        lines.append(f"※ 壁のループが閉じないため、面積は{layout.area_source}から求めています")
    lines.append(f"壁 {len(layout.walls)} 枚")
    for i, w in enumerate(layout.walls):
        marks = "".join({"door": "戸", "window": "窓"}.get(o.category, "口")
                        for o in sorted(w.openings, key=lambda x: x.start))
        lines.append(
            f"  {i}: 長さ {w.length:.2f} m  高さ {w.height:.2f} m"
            f"  ({w.p0[0]:+.2f},{w.p0[1]:+.2f})→({w.p1[0]:+.2f},{w.p1[1]:+.2f})"
            f"  {w.confidence}{'  開口 ' + marks if marks else ''}"
        )
    for cat, label in (("door", "ドア"), ("window", "窓"), ("opening", "開口")):
        items = layout.openings(cat)
        if items:
            widths = "  ".join(f"{o.width * 1000:.0f}mm" for o in items)
            lines.append(f"{label} {len(items)}: {widths}")
    if layout.furniture:
        names = "  ".join(FURNITURE_JA.get(f.category, f.category) for f in layout.furniture)
        lines.append(f"家具 {len(layout.furniture)}: {names}")
    return "\n".join(lines)
