"""撮影軌跡からツアーの station point を抽出する。

**なぜ自由視点にしないか。**
3DGS は撮影した視点から離れると破綻する。これは弱点だが、
ツアーの導線を撮影軌跡上に制約すれば「常に撮影視点の近傍しか描画しない」
＝3DGS が最も得意な条件だけを使うことになる。Matterport が
station point 方式を採るのも同じ理屈。docs/pipeline.md §8 参照。

station 間は隣接グラフでつなぎ、移動はカメラ補間で行う。
各 station では自由に見回せる。
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .mdr import Bundle, Frame


@dataclass
class Station:
    index: int
    #: ARKit world 座標の視点位置
    position: np.ndarray
    #: 撮影時にこの station で向いていた代表方向（正規化済み）
    forward: np.ndarray
    #: 元になったフレーム番号
    source_frame: int
    neighbors: list[int] = field(default_factory=list)


@dataclass
class Tour:
    stations: list[Station]
    #: 床面の高さ（ARKit world の Y）。視点高さの基準に使う
    floor_y: float
    eye_height: float

    def to_json(self) -> str:
        return json.dumps(
            {
                "version": 1,
                "floor_y": self.floor_y,
                "eye_height": self.eye_height,
                "stations": [
                    {
                        "index": s.index,
                        "position": [float(x) for x in s.position],
                        "forward": [float(x) for x in s.forward],
                        "source_frame": s.source_frame,
                        "neighbors": s.neighbors,
                    }
                    for s in self.stations
                ],
            },
            indent=2,
        )


def extract(
    bundle: Bundle,
    spacing: float = 1.0,
    neighbor_radius: float | None = None,
    floor_y: float | None = None,
    eye_height: float = 1.5,
) -> Tour:
    """撮影軌跡に沿って `spacing` 間隔で station を置く。

    軌跡上の点をそのまま使うので、station は必ず「実際にカメラがあった位置」
    になる。3DGS が破綻しない領域内に収まることが保証される。
    """
    frames = bundle.frames
    if not frames:
        raise ValueError("フレームがありません")

    pos = np.array([f.c2w_arkit[:3, 3] for f in frames])
    # ARKit のカメラは -Z を向く
    fwd = np.array([-f.c2w_arkit[:3, 2] for f in frames])

    # 軌跡に沿って spacing 間隔で候補を拾う
    picked = [0]
    travelled = 0.0
    for i in range(1, len(pos)):
        travelled += float(np.linalg.norm(pos[i] - pos[i - 1]))
        if travelled >= spacing:
            picked.append(i)
            travelled = 0.0

    # 撮影は同じ部屋を何周もするので、経路長で拾うと同じ物理位置に
    # station が積み重なる（外周3パス+中央パスなら最大4重）。
    # 空間的に近すぎるものは落とす。
    merge_dist = spacing * 0.6
    kept: list[int] = []
    for i in picked:
        if all(np.linalg.norm(pos[i] - pos[j]) >= merge_dist for j in kept):
            kept.append(i)
    picked = kept

    stations: list[Station] = []
    for n, i in enumerate(picked):
        f = fwd[i]
        # 上下の傾きは捨てて水平方向だけ残す。撮影時は床や天井を向いていることが
        # 多く、そのままツアーの初期方向にすると床を向いた状態で始まってしまう。
        f = np.array([f[0], 0.0, f[2]])
        norm = np.linalg.norm(f)
        f = f / norm if norm > 1e-6 else np.array([0.0, 0.0, -1.0])
        stations.append(
            Station(index=n, position=pos[i].copy(), forward=f, source_frame=frames[i].index)
        )

    radius = neighbor_radius if neighbor_radius is not None else spacing * 1.2
    _link(stations, radius)

    if floor_y is None:
        floor_y = float(np.percentile(pos[:, 1], 5)) - eye_height

    return Tour(stations=stations, floor_y=floor_y, eye_height=eye_height)


def _link(stations: list[Station], radius: float) -> None:
    """半径内の station をつなぎ、孤立が残れば最近傍を足して連結にする。"""
    p = np.array([s.position for s in stations])
    for i, s in enumerate(stations):
        d = np.linalg.norm(p - p[i], axis=1)
        s.neighbors = [int(j) for j in np.argsort(d)[1:] if d[j] <= radius]

    # 撮影経路が往復していると半径だけでは切れる区間が出る。
    # 軌跡順に隣り合う station は必ずつないでおく。
    for i in range(len(stations) - 1):
        if i + 1 not in stations[i].neighbors:
            stations[i].neighbors.append(i + 1)
        if i not in stations[i + 1].neighbors:
            stations[i + 1].neighbors.append(i)

    for s in stations:
        s.neighbors = sorted(set(s.neighbors))
