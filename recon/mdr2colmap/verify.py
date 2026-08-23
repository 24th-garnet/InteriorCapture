"""座標変換の検証。

学習に数分かけてから「なんか変」と気づくのを避けるための、秒で判定できるチェック。

**要点: 必ず別フレーム間で検証する。**
同じフレームの深度を非投影してそのフレームに投影し返すのは往復なので、
world 変換が間違っていても誤差が打ち消えて通ってしまう。
フレーム A の点をフレーム B に投影して初めてポーズが検証される。
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from .colmap import project
from .mdr import Bundle, Frame
from .pointcloud import PIXEL_CENTER_OFFSET, unproject_frame


#: 判定に必要な最小の重なり点数。これを下回るペアは「間違っている」ではなく
#: 「判定できない」として扱う。撮影中に視線を大きく振ると共通視野が消えるので、
#: 実データでは普通に起きる。ここを NG と report すると誤報になる。
MIN_POINTS_TO_JUDGE = 200


@dataclass
class ReprojectionResult:
    src_index: int
    dst_index: int
    n_points: int
    #: 投影先で測定された深度と、投影して得た深度の差（メートル）
    median_error: float
    p90_error: float
    inlier_ratio: float

    @property
    def judged(self) -> bool:
        """共通視野が足りていて判定に使えるか。"""
        return self.n_points >= MIN_POINTS_TO_JUDGE

    @property
    def ok(self) -> bool:
        """中央値 5cm 以内かつ 8 割が 10cm 以内なら変換は正しいとみなす。

        LiDAR 自体の誤差と ARKit のドリフトがあるので完全一致はしない。
        座標変換を間違えている場合はメートル単位でずれるため、判定は明快に分かれる。
        """
        return self.judged and self.median_error < 0.05 and self.inlier_ratio > 0.8

    def __str__(self) -> str:
        head = f"frame {self.src_index:>6} -> {self.dst_index:<6} n={self.n_points:>7}"
        if not self.judged:
            return f"--  {head}  重なり不足のため判定不能"
        mark = "OK  " if self.ok else "NG  "
        return (
            f"{mark}{head}  median={self.median_error*100:7.2f}cm  "
            f"p90={self.p90_error*100:7.2f}cm  inlier={self.inlier_ratio*100:5.1f}%"
        )


def check_pair(
    bundle: Bundle,
    src: Frame,
    dst: Frame,
    conf_min: int,
    inlier_thresh: float = 0.10,
) -> ReprojectionResult:
    """src の深度を非投影し dst に投影して、dst の実測深度と比べる。

    座標変換が正しければ両者は数 cm で一致する。間違っていればメートル単位でずれる。
    """
    xyz, _ = unproject_frame(bundle, src, conf_min, with_color=False)
    if len(xyz) == 0:
        return ReprojectionResult(src.index, dst.index, 0, np.inf, np.inf, 0.0)

    # dst のフル解像度画素座標に投影してから深度解像度に落とす
    uv, z_proj = project(xyz, dst.c2w_arkit, dst.intrinsics)

    dst_depth = bundle.depth(dst.index)
    dst_conf = bundle.confidence(dst.index)
    dh, dw = dst_depth.shape
    vw, vh = bundle.manifest.video_wh

    du = uv[:, 0] * dw / vw
    dv = uv[:, 1] * dh / vh

    inside = (
        (z_proj > 0)
        & (du >= 0)
        & (du < dw)
        & (dv >= 0)
        & (dv < dh)
    )
    if not inside.any():
        return ReprojectionResult(src.index, dst.index, 0, np.inf, np.inf, 0.0)

    ix = np.clip((du[inside] - PIXEL_CENTER_OFFSET).round().astype(np.int64), 0, dw - 1)
    iy = np.clip((dv[inside] - PIXEL_CENTER_OFFSET).round().astype(np.int64), 0, dh - 1)

    measured = dst_depth[iy, ix].astype(np.float64)
    conf = dst_conf[iy, ix]
    valid = (conf >= conf_min) & np.isfinite(measured) & (measured > 0)
    if not valid.any():
        return ReprojectionResult(src.index, dst.index, 0, np.inf, np.inf, 0.0)

    err = np.abs(z_proj[inside][valid] - measured[valid])
    return ReprojectionResult(
        src_index=src.index,
        dst_index=dst.index,
        n_points=int(valid.sum()),
        median_error=float(np.median(err)),
        p90_error=float(np.percentile(err, 90)),
        inlier_ratio=float((err < inlier_thresh).mean()),
    )


def check(
    bundle: Bundle, conf_min: int, n_pairs: int = 5, stride: int = 10
) -> list[ReprojectionResult]:
    """バンドル全体からペアを選んで検証する。"""
    frames = bundle.frames
    if len(frames) <= stride:
        raise ValueError(
            f"検証には {stride + 1} フレーム以上必要です（現在 {len(frames)}）"
        )

    usable = len(frames) - stride
    picks = np.linspace(0, usable - 1, num=min(n_pairs, usable), dtype=int)
    return [check_pair(bundle, frames[i], frames[i + stride], conf_min) for i in picks]


def render_overlay(
    bundle: Bundle,
    src: Frame,
    dst: Frame,
    conf_min: int,
    out_path: Path,
    max_points: int = 60000,
) -> None:
    """src の点を dst の画像に重ねた PNG を出す。

    点が物体の輪郭に乗っていれば座標変換は正しい。
    ずれていれば FLIP の向き、transform が camera->world である前提、
    深度側の内部パラメータのスケールの順に疑う。
    """
    xyz, _ = unproject_frame(bundle, src, conf_min, with_color=False)
    if len(xyz) == 0:
        raise ValueError(f"frame {src.index} から点が得られませんでした")

    if len(xyz) > max_points:
        sel = np.random.default_rng(0).choice(len(xyz), max_points, replace=False)
        xyz = xyz[sel]

    uv, z = project(xyz, dst.c2w_arkit, dst.intrinsics)
    img = np.asarray(Image.open(bundle.image_path(dst.index)).convert("RGB")).copy()
    ih, iw = img.shape[:2]

    ok = (z > 0) & (uv[:, 0] >= 0) & (uv[:, 0] < iw) & (uv[:, 1] >= 0) & (uv[:, 1] < ih)
    u = uv[ok, 0].astype(np.int64)
    v = uv[ok, 1].astype(np.int64)
    zz = z[ok]

    # 近い点を赤、遠い点を青にして深度の妥当性も目視できるようにする
    if len(zz):
        norm = np.clip((zz - zz.min()) / max(float(np.ptp(zz)), 1e-6), 0, 1)
        img[v, u, 0] = ((1 - norm) * 255).astype(np.uint8)
        img[v, u, 1] = 40
        img[v, u, 2] = (norm * 255).astype(np.uint8)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(img).save(out_path)
