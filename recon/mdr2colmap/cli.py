"""mdr2colmap のコマンドライン。

    mdr2colmap verify   room.mdr               # 座標変換とポーズの検証
    mdr2colmap roomplan room.mdr -o plan/      # RoomPlan から間取り図
    mdr2colmap floorplan room.mdr -o plan/     # メッシュから間取り図（room.json なしの旧データ用）
    mdr2colmap arrange  room.mdr --moves m.json -o out/   # 家具を切り分けて動かす

**3DGS は採用しない。** 解像度もガウシアン数も盲検で差が出ず、
サーバ側で計算資源を増やしても品質が上がらないと実測で確認したため
（`docs/experiments-server-quality.md`）。関連コード（COLMAP 書き出し・
初期点群・ポーズ精密化・station 抽出・splat ビューア）は削除済み。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import coords, floorplan, roomplan, segment, verify
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


def cmd_roomplan(args: argparse.Namespace) -> int:
    """RoomPlan の room.json から間取り図を作る。

    メッシュからの推定（`floorplan`）と違い、壁・ドア・窓が型付きで入っている。
    MDR と同じ ARSession で撮っているので座標系はメッシュ・station と一致する。
    """
    path = Path(args.bundle)
    if path.is_dir():
        path = path / "room.json"
    if not path.exists():
        print(f"エラー: room.json がありません: {path}", file=sys.stderr)
        print("RoomPlan を含む撮影が必要です（iOS 17 以降のビルド）。", file=sys.stderr)
        return 2

    fixes = roomplan.load_opening_fixes(args.fixes) if args.fixes else None
    layout = roomplan.load(path, opening_fixes=fixes)
    print(roomplan.summary(layout))
    medium = [o for w in layout.walls for o in w.openings if o.confidence == "medium"]
    if medium:
        print(f"※ 開口 {len(medium)} 件が confidence medium です。"
              f"種別の誤りは幾何では見分けられないので、実写で確認してください")

    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    (out / "plan.svg").write_text(roomplan.to_svg(layout, show_furniture=not args.no_furniture))
    (out / "plan.dxf").write_text(roomplan.to_dxf(layout))
    print(f"\n出力: {out}/plan.svg, {out}/plan.dxf")
    return 0


def cmd_arrange(args: argparse.Namespace) -> int:
    """家具を切り分け、指定があれば動かした 3D を書き出す。

    平面図の編集器（家具配置）が書き出す JSON を `--moves` に渡す。
    `--moves` なしなら切り分けの内訳だけを報告する。
    """
    bundle = Path(args.bundle)
    room = bundle / "room.json" if bundle.is_dir() else bundle
    if not room.exists():
        print(f"エラー: room.json がありません: {room}", file=sys.stderr)
        return 2

    layout = roomplan.load(room)
    fixes = segment.load_box_fixes(args.fix_boxes) if args.fix_boxes else None
    boxes = segment.boxes_from_room(room, fixes=fixes)
    if not boxes:
        print("家具が検出されていません。切り分ける対象がありません。", file=sys.stderr)
        return 1

    moves = segment.load_moves(args.moves) if args.moves else []
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)

    mesh_path = bundle / "mesh.ply" if bundle.is_dir() else None
    if mesh_path and mesh_path.exists():
        mesh = read_ply_mesh(mesh_path)
        res = segment.split_mesh(
            mesh, boxes, layout.floor_y,
            walls=None if args.no_carry else layout.walls,
            ceiling_y=None if args.no_carry else layout.ceiling_y)
        print(f"メッシュ {len(mesh.faces):,} 面")
        for b in boxes:
            part = res.parts.get(b.identifier)
            n = len(part.faces) if part else 0
            label = roomplan.FURNITURE_JA.get(b.category, b.category)
            warn = "  要確認 (confidence medium)" if b.confidence == "medium" else ""
            print(f"  {label:<8}{n:>9,} 面{warn}")
            if part is not None and n and args.parts:
                segment.write_ply_mesh(out / f"part_{b.category}.ply", part)
        print(f"  {'部屋':<8}{len(res.remainder.faces):>9,} 面"
              f"   床付近で除外 {res.floor_excluded:,}")
        if args.parts:
            segment.write_ply_mesh(out / "part_room.ply", res.remainder)
        if moves:
            merged = segment.arrange_mesh(
                mesh, boxes, layout.floor_y, moves,
                walls=None if args.no_carry else layout.walls,
                ceiling_y=None if args.no_carry else layout.ceiling_y)
            segment.write_ply_mesh(out / "arranged.ply", merged)
            print(f"  -> {out / 'arranged.ply'}  ({len(merged.faces):,} 面)")

    if args.splat:
        cloud = segment.read_splat_ply(args.splat)
        room_mask, masks = segment.split_splats(cloud.xyz, boxes, layout.floor_y)
        print(f"\nsplat {len(cloud):,} ガウシアン")
        for b in boxes:
            label = roomplan.FURNITURE_JA.get(b.category, b.category)
            print(f"  {label:<8}{int(masks[b.identifier].sum()):>9,}")
        print(f"  {'部屋':<8}{int(room_mask.sum()):>9,}")
        if moves:
            moved = segment.arrange_splats(cloud, boxes, layout.floor_y, moves)
            segment.write_splat_ply(out / "arranged_splat.ply", moved)
            print(f"  -> {out / 'arranged_splat.ply'}")

    if not moves:
        print("\n--moves に編集器の JSON を渡すと、動かした 3D を書き出します。")
    return 0



def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="mdr2colmap",
        description="MDR バンドルから間取り図と家具配置を作る",
    )
    sub = p.add_subparsers(dest="command", required=True)

    v = sub.add_parser("verify", help="座標変換とポーズを検証する")
    v.add_argument("bundle", help=".mdr ディレクトリ")
    v.add_argument("--conf-min", type=int, default=None,
                   help="採用する深度信頼度の下限。既定は実データの最大値（= high）")
    v.add_argument("--pairs", type=int, default=5, help="検証するフレームペア数")
    v.add_argument("--stride", type=int, default=10, help="ペアのフレーム間隔")
    v.add_argument("--overlay", default=None, help="重ね合わせ PNG の出力先ディレクトリ")
    v.set_defaults(func=cmd_verify)

    rp = sub.add_parser("roomplan", help="RoomPlan の room.json から間取り図を作る")
    rp.add_argument("bundle", help="MDR バンドル、または room.json")
    rp.add_argument("-o", "--output", default="plan", help="出力先ディレクトリ")
    rp.add_argument("--no-furniture", action="store_true", help="家具を描かない")
    rp.add_argument("--fixes", help="人手の訂正 JSON（openings = 開口の種別）")
    rp.set_defaults(func=cmd_roomplan)

    # room.json を持たない旧データ用。寸法は 3cm 以内で一致するが
    # 開口部（ドア・窓）は検出できない（閉まっていると壁と区別がつかない）。
    fp = sub.add_parser("floorplan", help="メッシュから間取りを抽出する（旧データ用）")
    fp.add_argument("bundle", help=".mdr ディレクトリ")
    fp.add_argument("-o", "--output", default=".", help="SVG/DXF の出力先")
    fp.set_defaults(func=cmd_floorplan)

    ar = sub.add_parser("arrange", help="RoomPlan の箱で家具を切り分け、動かす")
    ar.add_argument("bundle", help="MDR バンドル（room.json と mesh.ply を含む）")
    ar.add_argument("-o", "--output", default="arranged", help="出力先")
    ar.add_argument("--moves", help="平面図の編集器が書き出した JSON")
    ar.add_argument("--splat", help="splat の PLY も切り分ける（3DGS は採用外）")
    ar.add_argument("--parts", action="store_true", help="家具ごとの PLY も書き出す")
    ar.add_argument("--fix-boxes",
                    help="箱の位置補正 JSON。{識別子: {dx,dy,dz}}。"
                         "RoomPlan の confidence が medium の箱は外れることがある")
    ar.add_argument("--no-carry", action="store_true",
                    help="上に乗っている物を一緒に運ばない（箱の中だけ切り出す）")
    ar.set_defaults(func=cmd_arrange)

    args = p.parse_args(argv)
    try:
        return args.func(args)
    except MDRError as e:
        print(f"エラー: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
