"""MDR バンドル (iPadOS ARKit キャプチャ) を COLMAP モデル + LiDAR 初期点群に変換する。

仕様: spec/mdr-v1.md
設計: docs/pipeline.md §5
"""

from .mdr import Bundle, Frame, Intrinsics, Manifest, MDRError

__all__ = ["Bundle", "Frame", "Intrinsics", "Manifest", "MDRError"]
__version__ = "0.1.0"
