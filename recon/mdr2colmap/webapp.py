"""撮影済みバンドルを管理する、手元で動く Web アプリ。

iPad / iPhone のアプリが書き出した `.mdr` を置いたディレクトリを指すと、

- 一覧（撮影日・枚数・面数・未着色率・RoomPlan の有無）
- 平面図（`room.json` があればそれを、無ければメッシュから）
- 3D と家具の移動（平面図と同じ枠に載せるので同期は引き算だけ）

がブラウザで触れる。移動は `moves.json` としてバンドルに書き戻し、
`arrange` にそのまま渡せる。

**外部依存を足していない。** 単一利用者の手元道具なので `http.server` で
足りる。numpy / scipy / pillow は既存のまま。

重い処理は 1 つだけある。3D の部品化と間引きが 727,754 面で約 30 秒。
結果は `<bundle>/.web/geom.json` に置き、`mesh_vc.glb` の更新時刻で
作り直す。
"""
from __future__ import annotations

import hmac
import json
import math
import mimetypes
import os
import secrets
import threading
import traceback
from dataclasses import asdict
from functools import lru_cache
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

import numpy as np

from . import meshplan, roomplan, segment, webgeom
from .mesh import Mesh, read_ply_mesh

WEB_ROOT = Path(__file__).parent / "web"
#: 重い処理を同時に走らせない。1 台の Mac で 1 人が使う前提。
_build_lock = threading.Lock()
#: 合言葉を載せる cookie の名前。
COOKIE = "madoriba_token"


# --- バンドルの読み取り -----------------------------------------------------


def scan_list(root: Path) -> list[dict]:
    """`root` 直下の `.mdr` を新しい順に並べる。"""
    out = []
    for d in sorted(root.glob("*.mdr")):
        if not d.is_dir():
            continue
        out.append(summary(d))
    out.sort(key=lambda s: s.get("created") or "", reverse=True)
    return out


def summary(bundle: Path) -> dict:
    """一覧に出す情報。**壊れたバンドルでも落とさない。**"""
    s: dict = {"id": bundle.name, "name": bundle.stem}
    m = _read_json(bundle / "manifest.json")
    if m:
        s["created"] = m.get("created_at")
        s["frames"] = m.get("frame_count")
        s["duration"] = m.get("duration_sec")
        s["device"] = (m.get("device") or {}).get("model")
        s["video"] = m.get("video")
        s["depth"] = m.get("depth")
    b = _read_json(bundle / "bake.json")
    if b:
        vc = b.get("vertex_color") or {}
        s["triangles"] = b.get("triangles") or vc.get("triangles")
        s["bakeSec"] = b.get("elapsed_sec")
        s["unfilled"] = b.get("unfilled_ratio")
        s["vertexUnfilled"] = vc.get("unfilled_ratio")
        s["atlas"] = b.get("atlas_size")
        s["mmPerTexel"] = (b.get("unwrap_detail") or {}).get("mm_per_texel")
        rp = b.get("roomplan") or {}
        s["roomplanSec"] = rp.get("build_sec")
    s["hasRoom"] = (bundle / "room.json").exists()
    s["hasVertexColor"] = (bundle / "mesh_vc.glb").exists()
    s["hasClass"] = (bundle / "mesh_class.bin").exists()
    s["hasMoves"] = (bundle / "moves.json").exists()
    s["hasArranged"] = (bundle / "arranged.ply").exists()
    return s


def _read_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


# --- 平面図 -----------------------------------------------------------------


def plan_payload(bundle: Path) -> dict:
    """平面図のデータ。座標はすべて**主方向で回した枠・メートル**。

    3D（`webgeom.build`）と同じ枠に載せる。こうすると平面図で動かした量を
    そのまま 3D の平行移動に使える。
    """
    room_json = bundle / "room.json"
    if room_json.exists():
        return _plan_from_roomplan(room_json)
    mesh_path = bundle / "mesh.ply"
    if not mesh_path.exists():
        raise FileNotFoundError("room.json も mesh.ply も無い")
    return _plan_from_mesh(read_ply_mesh(mesh_path))


def _plan_from_roomplan(room_json: Path) -> dict:
    lay = roomplan.load(room_json)
    boxes = segment.boxes_from_room(room_json)
    th = np.array([math.atan2(*(w.p1 - w.p0)[::-1]) for w in lay.walls])
    Lw = np.array([w.length for w in lay.walls])
    ang = float(np.angle(np.sum(Lw * np.exp(4j * th)) / Lw.sum()) / 4)
    R = meshplan.rotation(ang)

    pts = np.array([p for w in lay.walls for p in (w.p0 @ R.T, w.p1 @ R.T)])
    poly = lay.floor_polygon @ R.T if lay.floor_polygon is not None else pts
    allp = np.vstack([pts, poly])
    x0, z0 = float(allp[:, 0].min()), float(allp[:, 1].min())

    def to(p):
        return [round(float(p[0] - x0), 4), round(float(p[1] - z0), 4)]

    walls = []
    for w in lay.walls:
        a, b = w.p0 @ R.T, w.p1 @ R.T
        walls.append(dict(a=to(a), b=to(b), height=round(w.height, 3),
                          openings=[dict(s=round(o.start, 4), e=round(o.end, 4),
                                         cat=o.category, sill=round(o.sill, 4),
                                         h=round(o.height, 4)) for o in w.openings]))
    objects = []
    for b in boxes:
        c = np.array([b.center[0], b.center[2]]) @ R.T
        ax = np.array([b.axes[0, 0], b.axes[2, 0]])
        ax = ax / max(float(np.linalg.norm(ax)), 1e-9)
        axr = ax @ R.T
        objects.append(dict(
            id=b.identifier, category=b.category,
            label=webgeom.FURNITURE_JA.get(b.category, b.category),
            confidence=b.confidence, c=to(c),
            w=round(float(b.half[0] * 2), 4), d=round(float(b.half[2] * 2), 4),
            h=round(float(b.half[1] * 2), 4),
            yaw=round(math.degrees(math.atan2(axr[1], axr[0])), 2)))

    return dict(source="roomplan",
                angle=round(math.degrees(ang), 2),
                rot=[[round(v, 6) for v in row] for row in R.tolist()],
                extent=[round(float(allp[:, 0].max() - x0), 4),
                        round(float(allp[:, 1].max() - z0), 4)],
                floor=[to(p) for p in poly] if lay.floor_polygon is not None else [],
                walls=walls, objects=objects,
                area=round(lay.area, 3), areaSource=lay.area_source,
                floorY=round(lay.floor_y, 4), ceilingY=round(lay.ceiling_y, 4),
                roomName=lay.room_name)


def _plan_from_mesh(mesh: Mesh) -> dict:
    p = meshplan.extract(mesh)
    if p is None:
        raise ValueError("平面が取れない（壁面が足りない）")
    pts = p.outline
    x0, z0 = float(pts[:, 0].min()), float(pts[:, 1].min())
    outline = [[round(float(q[0] - x0), 4), round(float(q[1] - z0), 4)] for q in pts]
    walls = [dict(a=outline[i], b=outline[(i + 1) % len(outline)],
                  height=round(p.height, 3), openings=[])
             for i in range(len(outline))]
    return dict(source="mesh",
                angle=round(p.angle, 2),
                rot=[[round(v, 6) for v in row]
                     for row in meshplan.rotation(math.radians(p.angle)).tolist()],
                extent=[round(float(pts[:, 0].max() - x0), 4),
                        round(float(pts[:, 1].max() - z0), 4)],
                floor=outline, walls=walls, objects=[],
                area=round(p.area, 3), areaSource="メッシュ内法",
                floorY=round(p.floor_y, 4), ceilingY=round(p.ceiling_y, 4),
                roomName="居室",
                reliable=p.reliable,
                floorSeen=round(p.floor_seen, 2), ceilingSeen=round(p.ceiling_seen, 2))


# --- 3D（重いのでキャッシュする）-------------------------------------------


def geom_payload(bundle: Path) -> dict:
    cache = bundle / ".web" / "geom.json"
    src = bundle / "mesh_vc.glb"
    if cache.exists() and src.exists() and cache.stat().st_mtime >= src.stat().st_mtime:
        return json.loads(cache.read_text())
    with _build_lock:
        g = webgeom.build(bundle)
        cache.parent.mkdir(exist_ok=True)
        cache.write_text(json.dumps(g))
    return g


# --- 家具の移動 -------------------------------------------------------------


def apply_moves(bundle: Path, moves_doc: dict) -> dict:
    """`moves.json` を書いて `arrange` を回し、`arranged.ply` を出す。"""
    (bundle / "moves.json").write_text(json.dumps(moves_doc, ensure_ascii=False, indent=2))
    room_json = bundle / "room.json"
    mesh_path = bundle / "mesh.ply"
    if not room_json.exists() or not mesh_path.exists():
        return {"ok": False, "error": "room.json か mesh.ply が無い"}
    moves = segment.load_moves(bundle / "moves.json")
    if not moves:
        return {"ok": True, "moved": 0, "note": "移動なし"}
    lay = roomplan.load(room_json)
    boxes = segment.boxes_from_room(room_json)
    mesh = read_ply_mesh(mesh_path)
    merged = segment.arrange_mesh(mesh, boxes, lay.floor_y, moves,
                                  walls=lay.walls, ceiling_y=lay.ceiling_y)
    out = bundle / "arranged.ply"
    segment.write_ply_mesh(out, merged)
    return {"ok": True, "moved": len(moves), "faces": int(len(merged.faces)),
            "path": str(out)}


# --- HTTP -------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    root: Path = Path(".")
    #: 合言葉。空なら認証しない（localhost 専用のときだけ）。
    token: str = ""
    #: 書き込みを禁じる。閲覧だけ配るときに使う。
    read_only: bool = False
    server_version = "madoriba-web"

    def _authorized(self) -> bool:
        """合言葉を照合する。**時間差で漏れないよう `compare_digest` を使う。**

        受け口は 3 つ。cookie（普段）、`Authorization: Bearer`（API 直叩き）、
        クエリ `?token=`（最初の 1 回。cookie に移して URL から消す）。
        """
        if not self.token:
            return True
        got = ""
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            got = auth[7:]
        if not got:
            for part in (self.headers.get("Cookie") or "").split(";"):
                k, _, v = part.strip().partition("=")
                if k == COOKIE:
                    got = v
        if not got:
            got = parse_qs(urlparse(self.path).query).get("token", [""])[0]
        return hmac.compare_digest(got, self.token)

    def _deny(self) -> None:
        body = ("合言葉が要ります。起動時に表示された URL "
                "（?token=… 付き）を開いてください。").encode()
        self.send_response(401)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):      # noqa: A003
        pass                                 # アクセスログは出さない

    # -- 応答の道具

    def _json(self, obj, status: int = 200) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _file(self, path: Path) -> None:
        if not path.exists() or not path.is_file():
            self._json({"error": "見つからない"}, 404)
            return
        ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _bundle(self, name: str) -> Path | None:
        """**`..` を弾く。** 手元とはいえ、パスをそのまま繋がない。"""
        d = (self.root / name).resolve()
        if self.root.resolve() not in d.parents or not d.is_dir():
            return None
        return d

    # -- ルーティング

    def do_GET(self) -> None:                # noqa: N802
        if not self._authorized():
            return self._deny()
        p = unquote(urlparse(self.path).path)
        try:
            # クエリで来た合言葉は cookie に移す。URL に残ると共有事故になる。
            q = parse_qs(urlparse(self.path).query).get("token", [""])[0]
            if q and p in ("/", "/index.html"):
                self.send_response(302)
                self.send_header("Set-Cookie",
                                 f"{COOKIE}={q}; Path=/; HttpOnly; SameSite=Strict")
                self.send_header("Location", "/")
                self.end_headers()
                return
            if p == "/" or p == "/index.html":
                return self._file(WEB_ROOT / "index.html")
            if p.startswith("/static/"):
                return self._file(WEB_ROOT / p[len("/static/"):])
            if p == "/api/scans":
                return self._json(scan_list(self.root))
            if p.startswith("/api/scans/"):
                rest = p[len("/api/scans/"):].split("/")
                bundle = self._bundle(rest[0])
                if bundle is None:
                    return self._json({"error": "バンドルが無い"}, 404)
                what = rest[1] if len(rest) > 1 else ""
                if what == "":
                    return self._json(summary(bundle))
                if what == "plan":
                    return self._json(plan_payload(bundle))
                if what == "geom":
                    return self._json(geom_payload(bundle))
                if what == "moves":
                    return self._json(_read_json(bundle / "moves.json") or {"moved": []})
                if what == "file" and len(rest) > 2:
                    return self._file(bundle / rest[2])
            self._json({"error": "そんな道は無い"}, 404)
        except Exception as e:               # noqa: BLE001
            traceback.print_exc()
            self._json({"error": str(e)}, 500)

    def do_PUT(self) -> None:                # noqa: N802
        self._write()

    def do_POST(self) -> None:               # noqa: N802
        self._write()

    def _write(self) -> None:
        if not self._authorized():
            return self._deny()
        if self.read_only:
            return self._json({"error": "閲覧専用で動いています"}, 403)
        p = unquote(urlparse(self.path).path)
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
            if p.startswith("/api/scans/"):
                rest = p[len("/api/scans/"):].split("/")
                bundle = self._bundle(rest[0])
                if bundle is None:
                    return self._json({"error": "バンドルが無い"}, 404)
                what = rest[1] if len(rest) > 1 else ""
                if what == "moves":
                    (bundle / "moves.json").write_text(
                        json.dumps(body, ensure_ascii=False, indent=2))
                    return self._json({"ok": True})
                if what == "arrange":
                    return self._json(apply_moves(bundle, body))
            self._json({"error": "そんな道は無い"}, 404)
        except Exception as e:               # noqa: BLE001
            traceback.print_exc()
            self._json({"error": str(e)}, 500)


def serve(root: str | Path, port: int = 8765, host: str = "127.0.0.1",
          token: str | None = None, read_only: bool = False) -> None:
    """起動する。

    **localhost 以外へ出すときは合言葉を必ず付ける。** このアプリは
    `moves.json` と `arranged.ply` を書くので、無防備に晒すと誰でも
    他人のスキャンを書き換えられる。合言葉が無いまま外向きに開こうと
    したら起動を止める。
    """
    Handler.root = Path(root).expanduser().resolve()
    Handler.read_only = read_only

    local = host in ("127.0.0.1", "localhost", "::1")
    tok = token or os.environ.get("MADORIBA_TOKEN") or ""
    if not local and not tok:
        tok = secrets.token_urlsafe(16)
        print("外向きに開くので合言葉を作りました。この URL を共有してください。")
    Handler.token = tok

    n = len(list(Handler.root.glob("*.mdr")))
    print(f"バンドル {n} 件  {Handler.root}", flush=True)
    if read_only:
        print("閲覧専用（書き込みを受け付けません）")
    shown = f"http://{host}:{port}/" + (f"?token={tok}" if tok else "")
    print(shown, flush=True)
    ThreadingHTTPServer((host, port), Handler).serve_forever()
