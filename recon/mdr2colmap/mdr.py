"""MDR v1 バンドルの読み込み。

仕様: spec/mdr-v1.md

このモジュールの責務は「ARKit の生値を素直に numpy に載せる」ことだけ。
座標変換は colmap.py が行う。
"""

from __future__ import annotations

import json
import zlib
from dataclasses import dataclass
from functools import cached_property
from pathlib import Path

import numpy as np

SCHEMA_VERSION = "mdr-1"

#: raw DEFLATE（zlib ヘッダなし）。iOS 側の COMPRESSION_ZLIB がこの形式を吐く。
RAW_DEFLATE_WBITS = -15


class MDRError(Exception):
    pass


@dataclass(frozen=True)
class Intrinsics:
    """video.width/height 基準のピンホール内部パラメータ。

    ARKit は OIS・手ぶれ補正・内部デジタルクロップに追随して毎フレーム再計算するため、
    セッション共通ではなくフレームごとに保持する。
    """

    fx: float
    fy: float
    cx: float
    cy: float

    def scaled_to(self, from_wh: tuple[int, int], to_wh: tuple[int, int]) -> "Intrinsics":
        """別解像度に線形スケールする。

        深度マップは RGB と同一 FOV（センタークロップではない）なので、
        深度側の内部パラメータは単純スケールで得られる。spec/mdr-v1.md 参照。
        """
        sx = to_wh[0] / from_wh[0]
        sy = to_wh[1] / from_wh[1]
        return Intrinsics(self.fx * sx, self.fy * sy, self.cx * sx, self.cy * sy)

    def as_matrix(self) -> np.ndarray:
        return np.array(
            [[self.fx, 0.0, self.cx], [0.0, self.fy, self.cy], [0.0, 0.0, 1.0]],
            dtype=np.float64,
        )


@dataclass(frozen=True)
class Frame:
    index: int
    timestamp: float
    #: ARFrame.camera.transform を 4x4 に直したもの。camera->world、ARKit 座標系のまま。
    c2w_arkit: np.ndarray
    intrinsics: Intrinsics
    tracking: str
    exif: dict
    conf_high_ratio: float | None
    sharpness: float | None


@dataclass(frozen=True)
class Manifest:
    session_id: str
    created_at: str
    device_model: str
    device_os: str
    has_lidar: bool
    video_wh: tuple[int, int]
    video_fps: int
    depth_wh: tuple[int, int]
    world_alignment: str
    gravity: np.ndarray | None
    frame_count: int
    duration_sec: float | None


def _parse_transform(values: list[float]) -> np.ndarray:
    """列優先 float[16] を 4x4 行列にする。

    ARKit の simd_float4x4 は列優先。reshape(4,4) だと「行に列が入る」ので転置が要る。
    ここを間違えると転置行列で計算が通ってしまい、症状が「なんとなくズレる」になる。
    """
    if len(values) != 16:
        raise MDRError(f"transform は 16 要素である必要があります: {len(values)}")
    return np.asarray(values, dtype=np.float64).reshape(4, 4).T


class Bundle:
    """.mdr ディレクトリ。"""

    def __init__(self, path: str | Path):
        self.path = Path(path)
        if not self.path.is_dir():
            raise MDRError(f"MDR バンドルが見つかりません: {self.path}")
        self.manifest = self._load_manifest()
        self.frames = self._load_poses()

    # -- 読み込み ------------------------------------------------------------

    def _load_manifest(self) -> Manifest:
        p = self.path / "manifest.json"
        if not p.exists():
            raise MDRError(f"manifest.json がありません: {p}")
        m = json.loads(p.read_text())

        got = m.get("schema_version")
        if got != SCHEMA_VERSION:
            raise MDRError(
                f"schema_version が非対応です: {got!r} (対応: {SCHEMA_VERSION!r})。"
                " spec/mdr-v1.md を確認してください。"
            )

        dev = m["device"]
        video = m["video"]
        depth = m["depth"]
        gravity = m.get("gravity")
        return Manifest(
            session_id=m["session_id"],
            created_at=m["created_at"],
            device_model=dev["model"],
            device_os=dev["os"],
            has_lidar=dev["has_lidar"],
            video_wh=(int(video["width"]), int(video["height"])),
            video_fps=int(video["fps"]),
            depth_wh=(int(depth["width"]), int(depth["height"])),
            world_alignment=m["world_alignment"],
            gravity=np.asarray(gravity, dtype=np.float64) if gravity else None,
            frame_count=int(m["frame_count"]),
            duration_sec=m.get("duration_sec"),
        )

    def _load_poses(self) -> list[Frame]:
        p = self.path / "poses.jsonl"
        if not p.exists():
            raise MDRError(f"poses.jsonl がありません: {p}")

        frames: list[Frame] = []
        for lineno, line in enumerate(p.read_text().splitlines(), start=1):
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError as e:
                raise MDRError(f"poses.jsonl:{lineno} が JSON として不正です: {e}") from e

            k = d["intrinsics"]
            frames.append(
                Frame(
                    index=int(d["i"]),
                    timestamp=float(d["t"]),
                    c2w_arkit=_parse_transform(d["transform"]),
                    intrinsics=Intrinsics(
                        float(k["fx"]), float(k["fy"]), float(k["cx"]), float(k["cy"])
                    ),
                    tracking=d["tracking"],
                    exif=d.get("exif", {}),
                    conf_high_ratio=d.get("conf_high_ratio"),
                    sharpness=d.get("sharpness"),
                )
            )

        if len(frames) != self.manifest.frame_count:
            raise MDRError(
                f"frame_count ({self.manifest.frame_count}) と poses.jsonl の行数"
                f" ({len(frames)}) が一致しません"
            )
        return frames

    # -- フレームデータ ------------------------------------------------------

    def image_path(self, index: int) -> Path:
        return self.path / "frames" / f"{index:06d}.jpg"

    def image_name(self, index: int) -> str:
        return f"{index:06d}.jpg"

    def _read_deflate(self, path: Path) -> bytes:
        if not path.exists():
            raise MDRError(f"ファイルがありません: {path}")
        try:
            return zlib.decompress(path.read_bytes(), RAW_DEFLATE_WBITS)
        except zlib.error as e:
            raise MDRError(f"raw DEFLATE として展開できません: {path} ({e})") from e

    def depth(self, index: int) -> np.ndarray:
        """深度マップ (H, W) float32、単位メートル。"""
        w, h = self.manifest.depth_wh
        raw = self._read_deflate(self.path / "frames" / f"{index:06d}.depth.zz")
        expected = w * h * 2
        if len(raw) != expected:
            raise MDRError(
                f"深度データのサイズが不正です frame={index}: {len(raw)} != {expected}"
            )
        return np.frombuffer(raw, dtype=np.float16).reshape(h, w).astype(np.float32)

    def confidence(self, index: int) -> np.ndarray:
        """信頼度マップ (H, W) uint8。ARConfidenceLevel の raw 値。"""
        w, h = self.manifest.depth_wh
        raw = self._read_deflate(self.path / "frames" / f"{index:06d}.conf.zz")
        expected = w * h
        if len(raw) != expected:
            raise MDRError(
                f"信頼度データのサイズが不正です frame={index}: {len(raw)} != {expected}"
            )
        return np.frombuffer(raw, dtype=np.uint8).reshape(h, w)

    def __len__(self) -> int:
        return len(self.frames)

    @cached_property
    def confidence_high_value(self) -> int:
        """`.high` を表す値。

        仕様では ARConfidenceLevel の raw 値 (0=low, 1=medium, 2=high) だが、
        1..3 として観測されるという報告があるため実データから判定する。
        DeviceProbe で実機の値域が確定したら、この推定は不要になる。

        1 フレームだけ見ると、たまたま high の画素が無いフレームを引いて
        過小評価する。複数フレームの最大値を取る。
        """
        if not self.frames:
            return 2
        picks = np.linspace(0, len(self.frames) - 1, num=min(16, len(self.frames)), dtype=int)
        observed = 0
        for p in picks:
            c = self.confidence(self.frames[int(p)].index)
            if c.size:
                observed = max(observed, int(c.max()))
        return observed if observed > 0 else 2
