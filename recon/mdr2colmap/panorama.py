"""station point ごとに実写真からパノラマを合成する。

**なぜメッシュのテクスチャではなくパノラマなのか。**
テクスチャはメッシュに焼くので、貼る先の形状精度（実測 4.4〜5.5mm）が
品質の上限を決める。実測でアトラス 2048→4096 の効果は 3 回とも
ゼロだった（元メッシュ・ポーズ補正後とも）。解像度を上げても
書き込む先の位置が合っていない。

パノラマは復元を経ず**実写真をそのまま球面に貼る**ので、この制約がない。
1920x1440 の元画質がそのまま出る。Matterport が採る方式でもあり、
不動産の内見資料としては最も素直な選択。

幾何は「どこに立っているか」「隣の station はどちらか」にだけ使い、
見た目の責任を負わせない。
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from PIL import Image

from .colmap import arkit_c2w_to_opencv_c2w
from .mdr import Bundle, Frame
from .tour import Station


@dataclass
class Panorama:
    station_index: int
    #: equirectangular 画像 (H, W, 3)。横 360 度・縦 180 度。
    image: np.ndarray
    #: 各画素が 1 枚以上のフレームで埋まった割合
    coverage: float
    used_frames: int


def render_station(
    bundle: Bundle,
    station: Station,
    width: int = 4096,
    radius: float = 1.2,
    max_frames: int = 120,
    feather: float = 0.15,
) -> Panorama:
    """station 周辺のフレームを equirectangular に合成する。

    視点が完全に一致しないフレームを混ぜるので、厳密には視差が残る。
    ただし内見資料の用途では、部屋の見た目が分かることが重要で、
    数 cm の視差より**元画質が保たれること**の方が価値が高い。

    `feather` は画面端の重み減衰。レンズ周辺は歪みと露出が不安定なので、
    中心ほど重く扱って継ぎ目を目立たなくする。
    """
    height = width // 2
    accum = np.zeros((height, width, 3), np.float32)
    weight = np.zeros((height, width), np.float32)

    # 出力画素に対応する視線方向をあらかじめ作る
    lon = (np.arange(width) + 0.5) / width * 2 * np.pi - np.pi
    lat = np.pi / 2 - (np.arange(height) + 0.5) / height * np.pi
    lon_g, lat_g = np.meshgrid(lon, lat)
    dirs = np.stack([
        np.cos(lat_g) * np.sin(lon_g),
        np.sin(lat_g),
        np.cos(lat_g) * np.cos(lon_g),
    ], axis=-1).reshape(-1, 3)

    pos = np.array([f.c2w_arkit[:3, 3] for f in bundle.frames])
    dist = np.linalg.norm(pos - station.position, axis=1)
    order = np.argsort(dist)
    picked = [i for i in order if dist[i] < radius][:max_frames]

    vw, vh = bundle.manifest.video_wh
    for i in picked:
        frame = bundle.frames[i]
        c2w = arkit_c2w_to_opencv_c2w(frame.c2w_arkit)
        R = c2w[:3, :3]
        # world 方向 → カメラ座標
        cam = dirs @ R
        z = cam[:, 2]
        front = z > 1e-6
        if not front.any():
            continue

        k = frame.intrinsics
        u = np.where(front, k.fx * cam[:, 0] / np.where(front, z, 1) + k.cx, -1)
        v = np.where(front, k.fy * cam[:, 1] / np.where(front, z, 1) + k.cy, -1)
        inside = front & (u >= 0) & (u < vw) & (v >= 0) & (v < vh)
        if not inside.any():
            continue

        idx = np.nonzero(inside)[0]
        img = np.asarray(Image.open(bundle.image_path(frame.index)).convert("RGB"), np.float32)
        iu = np.clip(u[idx].astype(np.int32), 0, vw - 1)
        iv = np.clip(v[idx].astype(np.int32), 0, vh - 1)

        # 画面中心ほど重く。端は歪みと露出が不安定。
        nx = (u[idx] / vw - 0.5) * 2
        ny = (v[idx] / vh - 0.5) * 2
        edge = np.maximum(np.abs(nx), np.abs(ny))
        w = np.clip((1.0 - edge) / max(feather, 1e-6), 0.0, 1.0).astype(np.float32)
        # 視点が近いフレームほど視差が小さいので優先する
        w *= np.float32(1.0 / (0.2 + dist[i]))

        ys, xs = np.divmod(idx, width)
        np.add.at(accum, (ys, xs), img[iv, iu] * w[:, None])
        np.add.at(weight, (ys, xs), w)

    filled = weight > 0
    out = np.zeros((height, width, 3), np.uint8)
    out[filled] = np.clip(accum[filled] / weight[filled][:, None], 0, 255).astype(np.uint8)

    return Panorama(
        station_index=station.index,
        image=out,
        coverage=float(filled.mean()),
        used_frames=len(picked),
    )
