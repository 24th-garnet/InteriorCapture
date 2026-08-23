"""mdr2colmap のコマンドライン。

    mdr2colmap verify  room.mdr              # 座標変換の検証（学習前に必ず通す）
    mdr2colmap convert room.mdr -o scene     # COLMAP モデル + 初期点群を書き出す
    msplat-train scene -n 7000 --eval        # 学習
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import colmap, floorplan, pointcloud, verify
from .mdr import Bundle, MDRError
from .mesh import read_ply_mesh


def _progress(prefix: str):
    def cb(n: int, total: int) -> None:
        if n % 25 == 0 or n == total:
            print(f"\r{prefix} {n}/{total}", end="", file=sys.stderr, flush=True)
            if n == total:
                print(file=sys.stderr)

    return cb


def _resolve_conf_min(bundle: Bundle, requested: int | None) -> int:
    if requested is not None:
        return requested
    high = bundle.confidence_high_value
    print(f"信頼度のしきい値を {high} (実データの最大値) と判定しました", file=sys.stderr)
    return high


def cmd_verify(args: argparse.Namespace) -> int:
    bundle = Bundle(args.bundle)
    conf_min = _resolve_conf_min(bundle, args.conf_min)

    print(
        f"{bundle.manifest.device_model} / {bundle.manifest.device_os} / "
        f"{len(bundle)} フレーム / video {bundle.manifest.video_wh} / "
        f"depth {bundle.manifest.depth_wh}"
    )
    print()
    print("フレーム間の再投影誤差（別フレームに投影して実測深度と比較）")

    results = verify.check(bundle, conf_min, n_pairs=args.pairs, stride=args.stride)
    for r in results:
        print("  " + str(r))

    if args.overlay:
        out = Path(args.overlay)
        for r in results:
            src = next(f for f in bundle.frames if f.index == r.src_index)
            dst = next(f for f in bundle.frames if f.index == r.dst_index)
            p = out / f"overlay_{r.src_index:06d}_to_{r.dst_index:06d}.png"
            verify.render_overlay(bundle, src, dst, conf_min, p)
            print(f"  重ね合わせ画像: {p}")

    print()
    judged = [r for r in results if r.judged]
    skipped = len(results) - len(judged)
    if skipped:
        print(f"{skipped} ペアは共通視野が足りず判定できませんでした（撮影の問題であり変換の問題ではない）。")

    if not judged:
        print("判定できるペアがありませんでした。--stride を小さくして試してください。")
        return 1

    if all(r.ok for r in judged):
        print(f"座標変換は正しいと判断できます（{len(judged)} ペアで検証）。")
        return 0

    print("座標変換がずれています。次の順に疑ってください:")
    print("  1. colmap.FLIP の適用側（カメラ側から掛けているか）")
    print("  2. transform が camera->world である前提と、列優先の読み取り")
    print("  3. 深度側 intrinsics のスケール（spec/mdr-v1.md の対応式）")
    return 1


def cmd_convert(args: argparse.Namespace) -> int:
    bundle = Bundle(args.bundle)
    conf_min = _resolve_conf_min(bundle, args.conf_min)

    out = Path(args.output)
    sparse = out / "sparse" / "0"
    images = out / "images"
    sparse.mkdir(parents=True, exist_ok=True)
    images.mkdir(parents=True, exist_ok=True)

    frames = bundle.frames
    names = [bundle.image_name(f.index) for f in frames]
    width, height = bundle.manifest.video_wh

    print(f"COLMAP モデルを書き出し中: {len(frames)} フレーム", file=sys.stderr)
    colmap.write_cameras_bin(sparse / "cameras.bin", frames, width, height)
    colmap.write_images_bin(sparse / "images.bin", frames, names)

    # 画像は既定でシンボリックリンク。1 部屋 180MB のコピーを避ける。
    for f, name in zip(frames, names):
        dst = images / name
        if dst.exists() or dst.is_symlink():
            dst.unlink()
        src = bundle.image_path(f.index).resolve()
        if args.copy:
            dst.write_bytes(src.read_bytes())
        else:
            dst.symlink_to(src)

    print("LiDAR 深度から初期点群を構築中", file=sys.stderr)
    xyz, rgb = pointcloud.build(
        bundle,
        frames,
        conf_min=conf_min,
        voxel=args.voxel,
        depth_range=(args.near, args.far),
        denoise=not args.no_denoise,
        progress=_progress("  非投影"),
    )
    colmap.write_points3d_ply(sparse / "points3D.ply", xyz, rgb)

    print()
    print(f"出力先: {out}")
    print(f"  カメラ  {len(frames)} (PINHOLE, フレームごとに 1 台)")
    print(f"  点群    {len(xyz):,} 点 (ボクセル {args.voxel*100:.0f}cm)")
    print()
    print("次のコマンドで学習できます:")
    print(f"  msplat-train {out} -n 7000 --eval")
    return 0


def cmd_floorplan(args: argparse.Namespace) -> int:
    bundle = Bundle(args.bundle)
    mesh_path = bundle.path / "mesh.ply"
    if not mesh_path.exists():
        print(f"エラー: mesh.ply がありません: {mesh_path}", file=sys.stderr)
        return 2

    mesh = read_ply_mesh(mesh_path)
    plan = floorplan.extract(mesh)
    inner = floorplan.interior_size(plan)

    print(f"床 {plan.levels.floor:+.2f} m / 天井 {plan.levels.ceiling:+.2f} m"
          f"  → 天井高 {plan.levels.height:.2f} m")
    print(f"壁の主方向 {plan.azimuth_deg:.0f}°   検出した壁 {len(plan.walls)} 枚")
    if inner:
        a = inner[0] * inner[1]
        print(f"内法 {inner[0]:.2f} x {inner[1]:.2f} m = {a:.1f} m2 ({a / 1.62:.1f} 畳)")
    else:
        w, d = plan.size
        print(f"外接 {w:.2f} x {d:.2f} m = {plan.footprint_area:.1f} m2"
              f"  (軸ごとに壁が2枚揃わなかったため内法は出せません)")

    for wl in sorted(plan.walls, key=lambda x: -x.area):
        ax = "X" if wl.axis == 0 else "Y"
        note = f"  開口候補 {len(wl.openings)}" if wl.openings else ""
        print(f"  壁 {ax}={wl.position:+6.2f} m  長さ {wl.length:5.2f} m"
              f"  面積 {wl.area:5.1f} m2{note}")

    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    (out / "floorplan.svg").write_text(floorplan.to_svg(plan))
    (out / "floorplan.dxf").write_text(floorplan.to_dxf(plan))
    print(f"\n出力: {out}/floorplan.svg, {out}/floorplan.dxf")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="mdr2colmap",
        description="MDR バンドルを COLMAP モデル + LiDAR 初期点群に変換する",
    )
    sub = p.add_subparsers(dest="command", required=True)

    def add_common(sp):
        sp.add_argument("bundle", help=".mdr ディレクトリ")
        sp.add_argument(
            "--conf-min",
            type=int,
            default=None,
            help="採用する深度信頼度の下限。既定は実データの最大値（= high）",
        )

    v = sub.add_parser("verify", help="座標変換を検証する（学習前に必ず実行）")
    add_common(v)
    v.add_argument("--pairs", type=int, default=5, help="検証するフレームペア数")
    v.add_argument("--stride", type=int, default=10, help="ペアのフレーム間隔")
    v.add_argument("--overlay", default=None, help="重ね合わせ PNG の出力先ディレクトリ")
    v.set_defaults(func=cmd_verify)

    c = sub.add_parser("convert", help="COLMAP モデルと初期点群を書き出す")
    add_common(c)
    c.add_argument("-o", "--output", required=True, help="出力ディレクトリ")
    c.add_argument("--voxel", type=float, default=0.02, help="ボクセルサイズ(m)")
    c.add_argument("--near", type=float, default=0.1, help="採用する深度の下限(m)")
    c.add_argument("--far", type=float, default=5.0, help="採用する深度の上限(m)")
    c.add_argument("--no-denoise", action="store_true", help="外れ値除去を行わない")
    c.add_argument("--copy", action="store_true", help="画像をリンクせずコピーする")
    c.set_defaults(func=cmd_convert)

    fp = sub.add_parser("floorplan", help="メッシュから間取り（壁線・寸法）を抽出する")
    fp.add_argument("bundle", help=".mdr ディレクトリ")
    fp.add_argument("-o", "--output", default=".", help="SVG/DXF の出力先")
    fp.set_defaults(func=cmd_floorplan)

    args = p.parse_args(argv)
    try:
        return args.func(args)
    except MDRError as e:
        print(f"エラー: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
