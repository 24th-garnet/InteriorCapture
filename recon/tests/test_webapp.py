"""Web アプリの読み取り。**壊れたバンドルで落ちないこと**が要点。

39 件の実データには、焼き込み前・RoomPlan なし・manifest が壊れている
ものが混ざる。一覧はそれら全部を並べられないといけない。
"""
import json
from pathlib import Path

from mdr2colmap import webapp


def make(root: Path, name: str, manifest=None, bake=None, files=()):
    d = root / name
    d.mkdir()
    if manifest is not None:
        (d / "manifest.json").write_text(json.dumps(manifest))
    if bake is not None:
        (d / "bake.json").write_text(json.dumps(bake))
    for f in files:
        (d / f).write_bytes(b"x")
    return d


def test_lists_only_mdr_directories(tmp_path):
    make(tmp_path, "room-a.mdr", manifest={"created_at": "2026-09-01T00:00:00"})
    (tmp_path / "notes.txt").write_text("x")
    (tmp_path / "Scaniverse").mkdir()
    out = webapp.scan_list(tmp_path)
    assert [s["id"] for s in out] == ["room-a.mdr"]


def test_newest_first(tmp_path):
    make(tmp_path, "room-old.mdr", manifest={"created_at": "2026-09-01T00:00:00"})
    make(tmp_path, "room-new.mdr", manifest={"created_at": "2026-09-20T00:00:00"})
    assert [s["name"] for s in webapp.scan_list(tmp_path)] == ["room-new", "room-old"]


def test_broken_manifest_still_lists(tmp_path):
    d = make(tmp_path, "room-broken.mdr")
    (d / "manifest.json").write_text("{ これは JSON ではない")
    out = webapp.scan_list(tmp_path)
    assert len(out) == 1
    assert out[0].get("created") is None


def test_flags_what_the_bundle_has(tmp_path):
    make(tmp_path, "room-full.mdr",
         manifest={"created_at": "2026-09-20T00:00:00", "frame_count": 375},
         bake={"elapsed_sec": 1.74, "triangles": 727754, "unfilled_ratio": 0.057,
               "unwrap_detail": {"mm_per_texel": 2.76}, "roomplan": {"build_sec": 5.7}},
         files=("room.json", "mesh_vc.glb", "mesh_class.bin"))
    s = webapp.scan_list(tmp_path)[0]
    assert s["hasRoom"] and s["hasVertexColor"] and s["hasClass"]
    assert not s["hasMoves"] and not s["hasArranged"]
    assert s["frames"] == 375
    assert s["mmPerTexel"] == 2.76
    assert s["roomplanSec"] == 5.7


def test_bundle_without_bake_is_fine(tmp_path):
    make(tmp_path, "room-raw.mdr", manifest={"created_at": "2026-09-20T00:00:00"})
    s = webapp.scan_list(tmp_path)[0]
    assert s["hasVertexColor"] is False
    assert "bakeSec" not in s or s["bakeSec"] is None
