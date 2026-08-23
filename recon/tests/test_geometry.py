"""座標変換の検証。

実機なしで数学だけを確かめる。ここが通っていれば、実データで再投影がずれたときに
「変換式ではなく ARKit の値の解釈が違う」と切り分けられる。

合成シーンは解析的に深度が求まる平面を使う。ARKit 規約でカメラを置き、
そこから見た深度マップを解析的に生成して MDR バンドルとして書き出し、
実際のパイプライン（非投影 → 別フレームへ投影）を通す。
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest
import zlib
from PIL import Image

from mdr2colmap import Bundle
from mdr2colmap.colmap import (
    FLIP,
    arkit_c2w_to_opencv_c2w,
    arkit_c2w_to_world2cam,
    qvec_to_rotmat,
    rotmat_to_qvec,
)
from mdr2colmap.mdr import _parse_transform
from mdr2colmap.pointcloud import PIXEL_CENTER_OFFSET, unproject_frame
from mdr2colmap.verify import check_pair

VIDEO_WH = (1920, 1440)
DEPTH_WH = (256, 192)
FX = FY = 1590.0
CX, CY = 960.0, 720.0

#: 世界に置く平面 n·p = d。ARKit world は Y 上なので、原点から -Z 方向 3m の壁。
PLANE_N = np.array([0.0, 0.0, 1.0])
PLANE_D = -3.0


def _deflate(raw: bytes) -> bytes:
    """iOS の COMPRESSION_ZLIB と同じ raw DEFLATE を作る。"""
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(raw) + c.flush()


def rot_y(deg: float) -> np.ndarray:
    a = np.radians(deg)
    return np.array([[np.cos(a), 0, np.sin(a)], [0, 1, 0], [-np.sin(a), 0, np.cos(a)]])


def make_pose(translation, yaw_deg=0.0) -> np.ndarray:
    """ARKit 規約の camera->world を作る（カメラは -Z を向く）。"""
    m = np.eye(4)
    m[:3, :3] = rot_y(yaw_deg)
    m[:3, 3] = translation
    return m


def render_depth(c2w_arkit: np.ndarray) -> np.ndarray:
    """このポーズから見た平面の深度マップを解析的に作る。"""
    dw, dh = DEPTH_WH
    kx = FX * dw / VIDEO_WH[0]
    ky = FY * dh / VIDEO_WH[1]
    cx = CX * dw / VIDEO_WH[0]
    cy = CY * dh / VIDEO_WH[1]

    us, vs = np.meshgrid(np.arange(dw), np.arange(dh))
    dirs = np.stack(
        [
            (us + PIXEL_CENTER_OFFSET - cx) / kx,
            (vs + PIXEL_CENTER_OFFSET - cy) / ky,
            np.ones_like(us, dtype=float),
        ],
        axis=-1,
    )

    c2w_cv = arkit_c2w_to_opencv_c2w(c2w_arkit)
    R, C = c2w_cv[:3, :3], c2w_cv[:3, 3]
    world_dirs = dirs @ R.T
    denom = world_dirs @ PLANE_N
    t = (PLANE_D - PLANE_N @ C) / denom
    return np.where(np.isfinite(t) & (t > 0), t, 0.0).astype(np.float32)


def write_bundle(root: Path, poses: list[np.ndarray]) -> Path:
    """合成 MDR バンドルを書き出す。"""
    bundle = root / "synthetic.mdr"
    (bundle / "frames").mkdir(parents=True)
    dw, dh = DEPTH_WH

    lines = []
    for i, pose in enumerate(poses):
        depth = render_depth(pose)
        (bundle / "frames" / f"{i:06d}.depth.zz").write_bytes(
            _deflate(depth.astype(np.float16).tobytes())
        )
        conf = np.full((dh, dw), 2, np.uint8)
        (bundle / "frames" / f"{i:06d}.conf.zz").write_bytes(_deflate(conf.tobytes()))
        Image.new("RGB", VIDEO_WH, (120, 130, 140)).save(bundle / "frames" / f"{i:06d}.jpg")

        lines.append(
            json.dumps(
                {
                    "i": i,
                    "t": float(i) / 30.0,
                    # 列優先で書く（ARKit / simd のメモリ並び）
                    "transform": pose.T.flatten().tolist(),
                    "intrinsics": {"fx": FX, "fy": FY, "cx": CX, "cy": CY},
                    "tracking": "normal",
                    "conf_high_ratio": 1.0,
                }
            )
        )
    (bundle / "poses.jsonl").write_text("\n".join(lines) + "\n")

    (bundle / "manifest.json").write_text(
        json.dumps(
            {
                "schema_version": "mdr-1",
                "session_id": "synthetic",
                "created_at": "2026-08-23T00:00:00Z",
                "device": {"model": "synthetic", "os": "n/a", "has_lidar": True},
                "video": {"width": VIDEO_WH[0], "height": VIDEO_WH[1], "fps": 30},
                "depth": {
                    "width": DEPTH_WH[0],
                    "height": DEPTH_WH[1],
                    "format": "float16",
                    "unit": "meter",
                },
                "world_alignment": "gravity",
                "gravity": [0.0, -1.0, 0.0],
                "frame_count": len(poses),
            }
        )
    )
    return bundle


@pytest.fixture
def synthetic(tmp_path: Path) -> Bundle:
    poses = [
        make_pose([0.0, 0.0, 0.0]),
        make_pose([0.30, 0.05, 0.0], yaw_deg=3.0),
        make_pose([0.60, 0.00, 0.1], yaw_deg=6.0),
    ]
    return Bundle(write_bundle(tmp_path, poses))


# -- 行列の規約 --------------------------------------------------------------


def test_transform_is_parsed_column_major():
    """列優先 float[16] が正しく 4x4 に戻ること。

    転置して読むと、平行移動成分が行に化けて「なんとなくズレる」症状になる。
    """
    m = np.arange(16, dtype=float).reshape(4, 4)
    assert np.allclose(_parse_transform(m.T.flatten().tolist()), m)


def test_flip_is_its_own_inverse():
    assert np.allclose(FLIP @ FLIP, np.eye(4))


def test_qvec_roundtrip():
    for yaw in (0.0, 17.0, 90.0, 179.0, -120.0):
        R = rot_y(yaw)
        assert np.allclose(qvec_to_rotmat(rotmat_to_qvec(R)), R, atol=1e-9)


def test_qvec_roundtrip_for_negative_trace():
    """trace が負の回転でも安定していること（素朴な実装が壊れる領域）。"""
    R = np.array([[-1.0, 0, 0], [0, -1.0, 0], [0, 0, 1.0]])
    assert np.allclose(qvec_to_rotmat(rotmat_to_qvec(R)), R, atol=1e-9)


def test_world2cam_inverts_pose():
    pose = make_pose([1.0, 2.0, 3.0], yaw_deg=30.0)
    w2c = arkit_c2w_to_world2cam(pose)
    assert np.allclose(w2c @ arkit_c2w_to_opencv_c2w(pose), np.eye(4), atol=1e-9)


# -- パイプライン ------------------------------------------------------------


def test_unprojected_points_lie_on_the_plane(synthetic: Bundle):
    """非投影した点が元の平面上に戻ること。内部パラメータのスケールを検証する。"""
    for frame in synthetic.frames:
        xyz, _ = unproject_frame(synthetic, frame, conf_min=2)
        assert len(xyz) > 1000
        residual = np.abs(xyz @ PLANE_N - PLANE_D)
        # float16 で保存しているので 3m 付近の量子化幅(約 2mm)が効く
        assert residual.max() < 0.01, f"frame {frame.index}: 最大残差 {residual.max():.4f}m"


def test_cross_frame_reprojection_is_consistent(synthetic: Bundle):
    """あるフレームの点を別フレームに投影して実測深度と一致すること。

    これが座標変換の本命の検証。同一フレームへの投影は往復なので、
    world 変換が誤っていても打ち消えて通ってしまう。
    """
    r = check_pair(synthetic, synthetic.frames[0], synthetic.frames[2], conf_min=2)
    assert r.n_points > 1000
    assert r.ok, str(r)
    assert r.median_error < 0.01, str(r)


def test_reprojection_check_detects_a_wrong_flip(synthetic: Bundle, monkeypatch):
    """FLIP を壊したら検証が落ちること。

    検証自体に検出力があることを確かめる。これが無いと
    「テストは通るが実は何も見ていない」状態に気づけない。
    """
    import mdr2colmap.colmap as colmap_mod

    monkeypatch.setattr(colmap_mod, "FLIP", np.eye(4))
    r = check_pair(synthetic, synthetic.frames[0], synthetic.frames[2], conf_min=2)
    assert not r.ok, "FLIP を恒等行列にしても検証が通ってしまいました"


# -- 向き付き初期化 ----------------------------------------------------------


def test_oriented_init_quaternion_aligns_normal(tmp_path):
    """書き出したクォータニオンが、z 軸を実際に法線へ写すこと。

    3DGS のガウシアンはローカル z 軸が第3スケール軸に対応する。
    法線方向を薄くするので、この回転が誤っていると「面に平行な薄い円盤」ではなく
    「面を貫く薄い板」になり、初期化が逆効果になる。
    """
    import numpy as np

    from mdr2colmap.colmap import qvec_to_rotmat, write_points3d_ply_oriented

    rng = np.random.default_rng(0)
    normals = rng.normal(size=(200, 3))
    normals /= np.linalg.norm(normals, axis=1, keepdims=True)
    # 真後ろ向き（縮退ケース）も混ぜる
    normals[0] = [0.0, 0.0, -1.0]
    normals[1] = [0.0, 0.0, 1.0]

    xyz = rng.normal(size=(200, 3))
    rgb = rng.integers(0, 256, size=(200, 3))
    p = tmp_path / "init.ply"
    write_points3d_ply_oriented(p, xyz, rgb, normals, spacing=0.02)

    got = _read_oriented_ply(p)
    assert len(got) == 200

    for i in (0, 1, 7, 55, 199):
        q = np.array([got["rot_0"][i], got["rot_1"][i], got["rot_2"][i], got["rot_3"][i]])
        R = qvec_to_rotmat(q)
        z_mapped = R @ np.array([0.0, 0.0, 1.0])
        assert np.allclose(z_mapped, normals[i], atol=1e-5), (
            f"i={i}: z 軸が {z_mapped} に写り、法線 {normals[i]} と一致しません"
        )


def test_oriented_init_is_flat_along_the_normal(tmp_path):
    """法線方向のスケールだけが薄いこと。"""
    import numpy as np

    from mdr2colmap.colmap import write_points3d_ply_oriented

    n = np.tile([0.0, 1.0, 0.0], (10, 1))
    p = tmp_path / "init.ply"
    write_points3d_ply_oriented(
        p, np.zeros((10, 3)), np.full((10, 3), 128), n, spacing=0.02, thickness_ratio=0.2
    )
    got = _read_oriented_ply(p)
    s = np.exp(np.stack([got["scale_0"], got["scale_1"], got["scale_2"]], 1))
    assert np.allclose(s[:, 0], 0.02, rtol=1e-4)
    assert np.allclose(s[:, 1], 0.02, rtol=1e-4)
    assert np.allclose(s[:, 2], 0.004, rtol=1e-4)


def _read_oriented_ply(path):
    """テスト用の最小 PLY リーダ。"""
    import re

    import numpy as np

    with open(path, "rb") as fh:
        head = b""
        while b"end_header" not in head:
            head += fh.readline()
        txt = head.decode("ascii")
        n = int(re.search(r"element vertex (\d+)", txt).group(1))
        names = re.findall(r"property float (\w+)", txt)
        dt = np.dtype([(nm, "<f4") for nm in names])
        return np.frombuffer(fh.read(n * dt.itemsize), dtype=dt, count=n)
