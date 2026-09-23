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


# --- 合言葉 -----------------------------------------------------------------
#
# **ここが破れると他人のスキャンを書き換えられる。** このアプリは
# moves.json と arranged.ply を書くので、外向きに出すなら必須。

import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import pytest


def run_server(tmp_path, token="", read_only=False):
    webapp.Handler.root = tmp_path
    webapp.Handler.token = token
    webapp.Handler.read_only = read_only
    srv = ThreadingHTTPServer(("127.0.0.1", 0), webapp.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}"


def get(url, token=None):
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def post(url, token=None, body=b"{}"):
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def test_token_gates_every_route(tmp_path):
    make(tmp_path, "room-a.mdr", manifest={"created_at": "2026-09-01T00:00:00"})
    srv, base = run_server(tmp_path, token="secret")
    try:
        assert get(f"{base}/api/scans") == 401
        assert get(f"{base}/api/scans", "wrong") == 401
        assert get(f"{base}/api/scans", "secret") == 200
        assert post(f"{base}/api/scans/room-a.mdr/moves") == 401
    finally:
        srv.shutdown()


def test_read_only_refuses_writes(tmp_path):
    make(tmp_path, "room-a.mdr", manifest={"created_at": "2026-09-01T00:00:00"})
    srv, base = run_server(tmp_path, token="secret", read_only=True)
    try:
        assert get(f"{base}/api/scans", "secret") == 200
        assert post(f"{base}/api/scans/room-a.mdr/moves", "secret",
                    b'{"moved":[]}') == 403
        assert not (tmp_path / "room-a.mdr" / "moves.json").exists()
    finally:
        srv.shutdown()


def test_cannot_escape_the_root(tmp_path):
    make(tmp_path, "room-a.mdr", manifest={"created_at": "2026-09-01T00:00:00"})
    srv, base = run_server(tmp_path)
    try:
        assert get(f"{base}/api/scans/..%2f..%2fetc/plan") == 404
        assert get(f"{base}/api/scans/nope.mdr/plan") == 404
    finally:
        srv.shutdown()
