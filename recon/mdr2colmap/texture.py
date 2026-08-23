"""キーフレームからメッシュにテクスチャを焼き込む。

Tier 1（撮影直後に手に入る成果物）の中核。3DGS の学習に比べて桁違いに軽く、
Scaniverse が A12Z 上で実現していることから実現可能性も確認済み。

このパイプライン固有の利点として、**LiDAR 深度マップをそのまま遮蔽判定に使える**。
通常のテクスチャ焼き込みはカメラごとにメッシュを深度レンダリングして
可視判定するが、ここでは実測深度と比較するだけで済む。

手順:
  1. xatlas で UV 展開
  2. UV 空間で三角形をラスタライズし、各テクセルの world 座標と法線を得る
  3. 各キーフレームに投影し、LiDAR 深度で遮蔽を判定
  4. 正対度・距離・シャープネスで重み付けして合成
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from PIL import Image

from .colmap import arkit_c2w_to_world2cam
from .mdr import Bundle, Frame
from .mesh import Mesh


@dataclass
class TexturedMesh:
    vertices: np.ndarray      # (N,3) world 座標
    faces: np.ndarray         # (M,3)
    uvs: np.ndarray           # (N,2)
    texture: np.ndarray       # (H,W,3) uint8
    #: テクセルのうち、どのフレームからも色を得られなかった割合
    unfilled_ratio: float


def unwrap(mesh: Mesh) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """UV 展開する。戻り値は (頂点, 面, UV)。頂点は UV 継ぎ目で複製される。"""
    import xatlas

    vmapping, indices, uvs = xatlas.parametrize(mesh.vertices, mesh.faces)
    return mesh.vertices[vmapping], indices.astype(np.int64), uvs


def _rasterize_atlas(
    verts: np.ndarray, faces: np.ndarray, uvs: np.ndarray, size: int
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """UV 空間で全三角形をラスタライズする。

    戻り値は (world 座標 (H,W,3), 法線 (H,W,3), 有効マスク (H,W))。

    三角形ごとに Python ループを回すと、1 三角形あたりの実作業が
    十数テクセルしかないのに Python のオーバーヘッドが支配的になる
    （173K 三角形で 16 秒）。バウンディングボックスの大きさで束ねて
    一括処理する。
    """
    pos = np.zeros((size, size, 3), np.float32)
    nrm = np.zeros((size, size, 3), np.float32)
    mask = np.zeros((size, size), bool)

    uv_px = (uvs * size).astype(np.float32)
    tri_uv = uv_px[faces]
    tri_xyz = verts[faces].astype(np.float32)

    e1 = tri_xyz[:, 1] - tri_xyz[:, 0]
    e2 = tri_xyz[:, 2] - tri_xyz[:, 0]
    face_n = np.cross(e1, e2)
    face_n /= np.maximum(np.linalg.norm(face_n, axis=1), 1e-12)[:, None]

    lo = np.clip(np.floor(tri_uv.min(axis=1)).astype(np.int32), 0, size - 1)
    hi = np.clip(np.ceil(tri_uv.max(axis=1)).astype(np.int32), 1, size)
    span = np.maximum(hi - lo, 1)
    extent = span.max(axis=1)

    a = tri_uv[:, 0]; b = tri_uv[:, 1]; c = tri_uv[:, 2]
    det = (b[:, 1] - c[:, 1]) * (a[:, 0] - c[:, 0]) + (c[:, 0] - b[:, 0]) * (a[:, 1] - c[:, 1])
    valid = np.abs(det) > 1e-9

    # 同じ窓サイズの三角形をまとめて処理する
    for k in np.unique(extent[valid]):
        sel = np.nonzero(valid & (extent == k))[0]
        if not len(sel):
            continue
        # (T, k, k) の格子。k は大半が数テクセルなのでメモリは小さい
        off = np.arange(k, dtype=np.float32) + 0.5
        gx = lo[sel, 0][:, None, None] + off[None, None, :]
        gy = lo[sel, 1][:, None, None] + off[None, :, None]

        aa, bb, cc = a[sel], b[sel], c[sel]
        dd = det[sel][:, None, None]
        w0 = ((bb[:, 1] - cc[:, 1])[:, None, None] * (gx - cc[:, 0][:, None, None])
              + (cc[:, 0] - bb[:, 0])[:, None, None] * (gy - cc[:, 1][:, None, None])) / dd
        w1 = ((cc[:, 1] - aa[:, 1])[:, None, None] * (gx - cc[:, 0][:, None, None])
              + (aa[:, 0] - cc[:, 0])[:, None, None] * (gy - cc[:, 1][:, None, None])) / dd
        w2 = 1.0 - w0 - w1

        inside = (w0 >= -0.002) & (w1 >= -0.002) & (w2 >= -0.002)
        inside &= (gx < size) & (gy < size)
        if not inside.any():
            continue

        ti, yi, xi = np.nonzero(inside)
        px = (lo[sel, 0][ti] + xi).astype(np.int32)
        py = (lo[sel, 1][ti] + yi).astype(np.int32)
        bary = np.stack([w0[ti, yi, xi], w1[ti, yi, xi], w2[ti, yi, xi]], axis=1)
        tri = tri_xyz[sel][ti]
        pos[py, px] = np.einsum("ij,ijk->ik", bary, tri)
        nrm[py, px] = face_n[sel][ti]
        mask[py, px] = True

    return pos, nrm, mask


def bake(
    bundle: Bundle,
    mesh: Mesh,
    size: int = 2048,
    conf_min: int = 2,
    depth_tolerance: float = 0.08,
    max_frames: int | None = None,
    view_exponent: float = 2.0,
    min_facing: float = 0.15,
    progress=None,
) -> TexturedMesh:
    """メッシュにテクスチャを焼き込む。"""
    verts, faces, uvs = unwrap(mesh)
    pos, nrm, mask = _rasterize_atlas(verts, faces, uvs, size)

    accum = np.zeros((size, size, 3), np.float64)
    weight = np.zeros((size, size), np.float64)

    flat_pos = pos[mask]              # (K,3)
    flat_nrm = nrm[mask]
    ys, xs = np.nonzero(mask)

    frames = bundle.frames
    if max_frames and len(frames) > max_frames:
        pick = np.linspace(0, len(frames) - 1, max_frames, dtype=int)
        frames = [frames[i] for i in pick]

    vw, vh = bundle.manifest.video_wh
    dw, dh = bundle.manifest.depth_wh
    sharp = np.array([f.sharpness or 1.0 for f in frames], float)
    sharp_norm = sharp / max(np.median(sharp), 1e-6)

    acc_flat = np.zeros((len(flat_pos), 3), np.float32)
    w_flat = np.zeros(len(flat_pos), np.float32)

    flat_pos32 = flat_pos.astype(np.float32)
    flat_nrm32 = flat_nrm.astype(np.float32)

    for n, frame in enumerate(frames):
        w2c = arkit_c2w_to_world2cam(frame.c2w_arkit)
        R = w2c[:3, :3].astype(np.float32)
        t = w2c[:3, 3].astype(np.float32)
        k = frame.intrinsics

        # 各段階で候補を絞ってから次の演算に進む。全テクセル(数百万)に対して
        # 最後まで演算し続けると、実際の作業量の数倍のコストがかかる。
        z = flat_pos32 @ R[2] + t[2]
        cand = np.nonzero(z > 0.05)[0]
        if not len(cand):
            continue

        p_c = flat_pos32[cand]
        zc = z[cand]
        xc = p_c @ R[0] + t[0]
        yc = p_c @ R[1] + t[1]
        u = k.fx * xc / zc + k.cx
        v = k.fy * yc / zc + k.cy
        keep = (u >= 0) & (u < vw) & (v >= 0) & (v < vh)
        if not keep.any():
            continue
        cand = cand[keep]
        u, v, zc = u[keep], v[keep], zc[keep]
        xc, yc = xc[keep], yc[keep]

        # 正対度。カメラから見て面が寝ているほど信用しない
        inv = 1.0 / np.sqrt(xc * xc + yc * yc + zc * zc)
        n_c = flat_nrm32[cand]
        nx = n_c @ R[0]; ny = n_c @ R[1]; nz = n_c @ R[2]
        facing = -(nx * xc + ny * yc + nz * zc) * inv
        keep = facing > min_facing
        if not keep.any():
            continue
        cand = cand[keep]
        u, v, zc, facing = u[keep], v[keep], zc[keep], facing[keep]

        # LiDAR 深度で遮蔽を判定する。メッシュを深度レンダリングせずに済む。
        depth = bundle.depth(frame.index)
        conf = bundle.confidence(frame.index)
        du = (u * (dw / vw)).astype(np.int32)
        dv = (v * (dh / vh)).astype(np.int32)
        np.clip(du, 0, dw - 1, out=du)
        np.clip(dv, 0, dh - 1, out=dv)
        measured = depth[dv, du]
        vis = (conf[dv, du] >= conf_min) & np.isfinite(measured) & (np.abs(measured - zc) < depth_tolerance)
        if not vis.any():
            continue
        cand = cand[vis]
        u, v, zc, facing = u[vis], v[vis], zc[vis], facing[vis]

        img = np.asarray(Image.open(bundle.image_path(frame.index)).convert("RGB"))
        iu = u.astype(np.int32); iv = v.astype(np.int32)
        np.clip(iu, 0, vw - 1, out=iu); np.clip(iv, 0, vh - 1, out=iv)

        # view_exponent を上げるほど「最良の1視点」に近づき、鮮鋭になる。
        # 低いと多視点の平均でボケるが、視点境界の継ぎ目は目立たなくなる。
        w = (facing ** view_exponent) / np.maximum(zc, 0.2) * sharp_norm[n]
        np.add.at(acc_flat, cand, img[iv, iu].astype(np.float32) * w[:, None])
        np.add.at(w_flat, cand, w)

        if progress:
            progress(n + 1, len(frames))

    filled = w_flat > 0
    color = np.zeros((len(flat_pos), 3), np.float64)
    color[filled] = acc_flat[filled] / w_flat[filled][:, None]

    accum[ys, xs] = color
    weight[ys, xs] = w_flat

    tex = np.clip(accum, 0, 255).astype(np.uint8)
    tex = _fill_holes(tex, (weight > 0))

    return TexturedMesh(
        vertices=verts,
        faces=faces,
        uvs=uvs,
        texture=tex,
        unfilled_ratio=float((~filled).mean()) if len(filled) else 1.0,
    )


def _fill_holes(tex: np.ndarray, filled: np.ndarray, iterations: int = 4) -> np.ndarray:
    """色が入らなかったテクセルを近傍から埋める。

    UV チャートの縁は、テクスチャ補間時に隣のチャートの色を拾って
    継ぎ目として見えるため、少なくとも数テクセルは外側へ広げておく。
    """
    out = tex.copy()
    known = filled.copy()
    for _ in range(iterations):
        if known.all():
            break
        pad_c = np.pad(out, ((1, 1), (1, 1), (0, 0)), mode="edge").astype(np.float64)
        pad_k = np.pad(known, ((1, 1), (1, 1)), mode="edge").astype(np.float64)
        s = np.zeros_like(pad_c[1:-1, 1:-1])
        c = np.zeros_like(pad_k[1:-1, 1:-1])
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy == 0 and dx == 0:
                    continue
                sl = (slice(1 + dy, pad_k.shape[0] - 1 + dy), slice(1 + dx, pad_k.shape[1] - 1 + dx))
                s += pad_c[sl] * pad_k[sl][..., None]
                c += pad_k[sl]
        grow = (~known) & (c > 0)
        out[grow] = (s[grow] / c[grow][:, None]).astype(np.uint8)
        known |= grow
    return out


# -- 書き出し ----------------------------------------------------------------


def to_glb(tm: TexturedMesh, path) -> None:
    """テクスチャ付き GLB を書く。Quick Look・Blender・Three.js で開ける。

    Scaniverse の出力と同じ構成（POSITION + TEXCOORD_0 + JPEG テクスチャ 1 枚）。
    """
    import io
    import json
    import struct
    from pathlib import Path

    path = Path(path)
    v = tm.vertices.astype("<f4")
    # glTF の UV 原点は画像左上で、アトラスも v=0 を上端としてラスタライズしている
    # （texture._rasterize_atlas 参照）。したがって上下反転は不要。
    # ここで反転すると、チャートが散在するアトラス上の全く別の位置を参照し、
    # 「ランダムなパッチワーク」に見える。
    uv = tm.uvs.astype("<f4")
    idx = tm.faces.astype("<u4").ravel()

    buf = io.BytesIO()
    def put(arr: np.ndarray) -> tuple[int, int]:
        off = buf.tell()
        buf.write(arr.tobytes())
        while buf.tell() % 4:
            buf.write(b"\x00")
        return off, arr.nbytes

    v_off, v_len = put(v)
    uv_off, uv_len = put(uv)
    i_off, i_len = put(idx)
    jpg = io.BytesIO()
    Image.fromarray(tm.texture).save(jpg, format="JPEG", quality=90)
    t_off, t_len = put(np.frombuffer(jpg.getvalue(), np.uint8))
    blob = buf.getvalue()

    gltf = {
        "asset": {"version": "2.0", "generator": "madoriba-recon"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "meshes": [{"primitives": [{
            "attributes": {"POSITION": 0, "TEXCOORD_0": 1},
            "indices": 2, "material": 0,
        }]}],
        "materials": [{
            "pbrMetallicRoughness": {
                "baseColorTexture": {"index": 0},
                "metallicFactor": 0.0,
                "roughnessFactor": 0.9,
            },
            "doubleSided": True,
        }],
        "textures": [{"source": 0, "sampler": 0}],
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071}],
        "images": [{"bufferView": 3, "mimeType": "image/jpeg"}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": len(v), "type": "VEC3",
             "min": v.min(0).tolist(), "max": v.max(0).tolist()},
            {"bufferView": 1, "componentType": 5126, "count": len(uv), "type": "VEC2"},
            {"bufferView": 2, "componentType": 5125, "count": len(idx), "type": "SCALAR"},
        ],
        "bufferViews": [
            {"buffer": 0, "byteOffset": v_off, "byteLength": v_len, "target": 34962},
            {"buffer": 0, "byteOffset": uv_off, "byteLength": uv_len, "target": 34962},
            {"buffer": 0, "byteOffset": i_off, "byteLength": i_len, "target": 34963},
            {"buffer": 0, "byteOffset": t_off, "byteLength": t_len},
        ],
        "buffers": [{"byteLength": len(blob)}],
    }

    js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    js += b" " * (-len(js) % 4)
    blob += b"\x00" * (-len(blob) % 4)

    with path.open("wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob)))
        fh.write(struct.pack("<II", len(js), 0x4E4F534A)); fh.write(js)
        fh.write(struct.pack("<II", len(blob), 0x004E4942)); fh.write(blob)
