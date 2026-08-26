"""フレーム間の露出差を揃える。

ARKit の自動露出は ISO を 160〜1600 の間で動かす。窓を向いたか壁を向いたかで
反応するので、**同じ壁がフレームによって 20 レベル違う明るさで写る**。
3DGS にもテクスチャ焼き込みにも露出差を表現する手段はないため、矛盾した観測を
平均するしかなく、どのフレームが優勢かで場所ごとに明るさが変わる。これがムラになる。

実測（本番の部屋・408 フレーム）:

    ムラ         6.45 -> 5.61
    露出ずれ σ    5.62 -> 2.89
    PSNR        25.08 -> 26.63
    白飛び        2.15% -> 0.95%

**解像度やガウシアン数ではムラは動かない**（5.9〜6.5 で一定）。計算資源では
解けない問題で、盲検で目視の有意差が確認できた唯一の施策でもある。

解き方
------
同じ 3 次元点を見ている全フレームで、その点が同じ色になるゲインを求める::

    log g_j + log a_i = log c_ij     g_j = フレーム j の露出係数
                                     a_i = 点 i の本来の色
                                     c_ij = 点 i がフレーム j に写った色

未知数は g と a の両方だが、観測は疎な二部グラフなので lsqr で解ける。
求まった g は EXIF の ISO と相関 0.92 で、カメラが実際に行った露出補正を
復元していることが確認できている。

**補正は g で割る。** c_ij = a_i * e_j なので上の式の g_j は e_j そのもの。
掛けると露出差が 2 倍になる（実測で点ごとのばらつきが 80% 悪化した）。

**リニア光で適用する。** 露出はリニア光での掛け算で、JPEG のガンマがかかった
値のまま掛けても露出補正にならない。
"""

from __future__ import annotations

import concurrent.futures as cf
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.sparse import coo_matrix, vstack
from scipy.sparse.linalg import lsqr

from .colmap import arkit_c2w_to_world2cam
from .mdr import Bundle, Frame

#: 対応付けに使う点の数。ゲインはフレームごとに 1 個なので、これで十分。
N_POINTS = 20_000
#: 色の採取に使う画像の幅。ゲインは全体量なので原寸で読む必要がない。
#: 原寸 1920 で読むと採取だけで 2 分かかる。
SAMPLE_WIDTH = 480
#: 可視判定の許容差。LiDAR 深度との差がこれを超えたら遮蔽とみなす。
DEPTH_TOL = 0.05
#: 露出が振り切れている画素は対応付けに使わない。
VALID_RANGE = (12, 243)
#: 求解時のゲインの上下限。外れ値で暴れないよう抑える。
SOLVE_CLAMP = (0.25, 4.0)
#: 補正倍率の上下限（中央値を 1.0 としたときの比）。
#:
#: 掃引して決めた。整合性の改善はここで頭打ちになる::
#:
#:     0.80-1.25  22.5%      0.62-1.62  38.7%
#:     0.70-1.43  32.7%      0.55-1.82  42.1%  <- 採用
#:                           0.45-2.20  42.2%  （広げても増えない）
CORRECTION_CLAMP = (0.55, 1.82)


@dataclass
class PhotometricResult:
    gains: np.ndarray          #: (N,) フレームごとの露出係数
    brightness_scale: float    #: 明るさを戻すために全体へ掛けた倍率
    observations: int          #: 対応付けに使えた観測数


def srgb_to_linear(x: np.ndarray) -> np.ndarray:
    c = x / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(y: np.ndarray) -> np.ndarray:
    c = np.clip(y, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055) * 255.0


def _observe(
    bundle: Bundle, frames: list[Frame], xyz: np.ndarray
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """点 × フレームの観測色を集める。戻り値は (点index, フレームindex, リニア色)。"""
    vw, vh = bundle.manifest.video_wh
    pi, fj, cc = [], [], []

    for j, f in enumerate(frames):
        w2c = arkit_c2w_to_world2cam(f.c2w_arkit)
        cam = xyz @ w2c[:3, :3].T + w2c[:3, 3]
        z = cam[:, 2]
        front = z > 1e-3
        if not front.any():
            continue
        k = f.intrinsics
        safe = np.where(front, z, 1.0)
        u = k.fx * cam[:, 0] / safe + k.cx
        v = k.fy * cam[:, 1] / safe + k.cy
        inside = front & (u >= 0) & (u < vw) & (v >= 0) & (v < vh)
        if not inside.any():
            continue

        depth = bundle.depth(f.index)
        dh, dw = depth.shape
        du = np.clip((u[inside] * dw / vw).astype(int), 0, dw - 1)
        dv = np.clip((v[inside] * dh / vh).astype(int), 0, dh - 1)
        dz = depth[dv, du]
        vis = np.isfinite(dz) & (np.abs(dz - z[inside]) < DEPTH_TOL)
        if not vis.any():
            continue

        # 色は縮小して読む。ゲインはフレーム全体の量なので精度は足りる。
        img = Image.open(bundle.image_path(f.index)).convert("RGB")
        sw = SAMPLE_WIDTH
        sh = max(1, round(sw * img.height / img.width))
        small = np.asarray(img.resize((sw, sh), Image.BILINEAR), np.float64)
        iu = np.clip((u[inside][vis] * sw / vw).astype(int), 0, sw - 1)
        iv = np.clip((v[inside][vis] * sh / vh).astype(int), 0, sh - 1)
        col = small[iv, iu]

        lum = col.mean(axis=1)
        ok = (lum > VALID_RANGE[0]) & (lum < VALID_RANGE[1])
        if not ok.any():
            continue

        pts = np.nonzero(inside)[0][vis][ok]
        pi.append(pts)
        fj.append(np.full(len(pts), j))
        cc.append(srgb_to_linear(col[ok]).mean(axis=1))

    if not pi:
        return np.zeros(0, int), np.zeros(0, int), np.zeros(0)
    return np.concatenate(pi), np.concatenate(fj), np.concatenate(cc)


def _solve(pi: np.ndarray, fj: np.ndarray, c: np.ndarray, n_frames: int) -> np.ndarray:
    """log g_j + log a_i = log c_ij を最小二乗で解く。"""
    _, pk = np.unique(pi, return_inverse=True)
    n_pts = int(pk.max()) + 1
    m = len(pi)
    rows = np.arange(m)

    A = coo_matrix(
        (np.ones(2 * m),
         (np.concatenate([rows, rows]), np.concatenate([fj, n_frames + pk]))),
        shape=(m, n_frames + n_pts),
    )
    # ゲージ固定: log g の平均を 0 に寄せる行。これがないと解が一意に決まらない。
    gauge = coo_matrix(
        (np.ones(n_frames), (np.zeros(n_frames, int), np.arange(n_frames))),
        shape=(1, n_frames + n_pts),
    )
    M = vstack([A, gauge * np.sqrt(m)]).tocsr()
    b = np.concatenate([np.log(np.clip(c, 1e-4, None)), [0.0]])
    sol = lsqr(M, b, atol=1e-10, btol=1e-10, iter_lim=2000)[0]
    return np.clip(np.exp(sol[:n_frames]), *SOLVE_CLAMP)


def _write_one(args) -> None:
    src, dst, divisor, scale, seed = args
    im = np.asarray(Image.open(src).convert("RGB"), np.float64)
    srgb = linear_to_srgb(srgb_to_linear(im) / divisor * scale)
    # 量子化前に三角ディザを載せる。暗くする方向の補正は 8bit の階調を削り、
    # そのまま丸めると縞になる（実測で 255 -> 148 階調）。雑音に変えれば
    # 平均としては階調情報が残り、幅によらず 240 前後を保つ。
    srgb += np.random.default_rng(seed).triangular(-1.0, 0.0, 1.0, size=srgb.shape)
    Image.fromarray(np.clip(srgb, 0, 255).round().astype(np.uint8)).save(dst, quality=95)


def correct(
    bundle: Bundle,
    frames: list[Frame],
    xyz: np.ndarray,
    names: list[str],
    out_dir: Path,
    darken_only: bool = True,
    progress=None,
) -> PhotometricResult:
    """露出を揃えた画像を `out_dir` に書き出す。

    `darken_only` は明るくする方向の補正を行わない。明るくすると白飛びが増え
    （実測で 2.15% -> 3.68%）、飛んだ画素は情報が消えるので、揃えたはずが
    かえって矛盾を増やす。代償として全体が 9% 暗くなる。
    """
    if len(xyz) > N_POINTS:
        xyz = xyz[np.linspace(0, len(xyz) - 1, N_POINTS).astype(int)]

    pi, fj, c = _observe(bundle, frames, xyz)
    if len(pi) < len(frames) * 10:
        # 対応付けが取れないときは補正しない。無理に解くと暴れる。
        gains = np.ones(len(frames))
    else:
        gains = _solve(pi, fj, c, len(frames))

    gains = np.clip(gains / np.median(gains), *CORRECTION_CLAMP)
    if darken_only:
        gains = gains / gains.min()

    # 明るさを戻す。暗いままだと成果物として見劣りするが、明るくしすぎると
    # 白飛びが増える。元の白飛び率を超えない範囲で最大限戻す。
    scale = _brightness_scale(bundle, frames, gains)

    out_dir.mkdir(parents=True, exist_ok=True)
    jobs = [
        (bundle.image_path(f.index), out_dir / n, gains[j], scale, j)
        for j, (f, n) in enumerate(zip(frames, names))
    ]
    with cf.ProcessPoolExecutor() as pool:
        for i, _ in enumerate(pool.map(_write_one, jobs, chunksize=8), start=1):
            if progress:
                progress(i, len(jobs))

    return PhotometricResult(gains=gains, brightness_scale=scale, observations=len(pi))


def _brightness_scale(bundle: Bundle, frames: list[Frame], gains: np.ndarray) -> float:
    """白飛びが元の水準を超えない範囲で、最大限明るく戻す倍率。"""
    step = max(1, len(frames) // 16)
    picked = list(range(0, len(frames), step))
    lins, base = [], 0.0
    total = 0
    for j in picked:
        im = np.asarray(Image.open(bundle.image_path(frames[j].index)).convert("RGB"), np.float64)
        base += float((im >= 254).sum())
        total += im.size
        lins.append(srgb_to_linear(im) / gains[j])
    base /= max(total, 1)

    best = 1.0
    for k in np.arange(1.0, 3.01, 0.05):
        clip = sum(float((lin * k >= 1.0).sum()) for lin in lins) / max(total, 1)
        if clip > base:
            break
        best = float(k)
    return best
