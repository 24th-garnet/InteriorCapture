import SwiftUI
import simd

/// world (X, Z) と画面座標の対応。**描画と当たり判定で同じ物を使う。**
/// 別々に計算すると、指を置いた位置と選ばれる要素がずれる。
struct PlanTransform {
    var scale: CGFloat      // 画面 px / メートル
    var origin: CGPoint     // world (minX, minZ) の画面位置

    /// **+Z は画面下。反転してはいけない。**
    ///
    /// 真上（+Y 側）から見下ろす右手系では、画面右を +X に取ると画面上は -Z
    /// になる（X × (-Z) = +Y = 視点方向）。+Z を上にすると鏡像の間取り図に
    /// なり、3D モデルと見比べたときにドアが逆側に出る。
    func point(_ p: SIMD2<Double>) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(p.x) * scale,
                y: origin.y + CGFloat(p.y) * scale)
    }

    func world(_ p: CGPoint) -> SIMD2<Double> {
        SIMD2(Double((p.x - origin.x) / scale), Double((p.y - origin.y) / scale))
    }

    /// 図が収まるように決める。`pad` は壁の外側に取る余白（メートル）。
    static func fit(_ bounds: (minX: Double, minZ: Double, maxX: Double, maxZ: Double),
                    in size: CGSize, pad: Double = 0.7) -> PlanTransform {
        let w = (bounds.maxX - bounds.minX) + pad * 2
        let h = (bounds.maxZ - bounds.minZ) + pad * 2
        guard w > 0, h > 0, size.width > 0, size.height > 0 else {
            return PlanTransform(scale: 1, origin: .zero)
        }
        let s = min(size.width / CGFloat(w), size.height / CGFloat(h))
        let drawn = CGSize(width: CGFloat(w) * s, height: CGFloat(h) * s)
        let ox = (size.width - drawn.width) / 2 + CGFloat(pad) * s
        let oy = (size.height - drawn.height) / 2 + CGFloat(pad) * s
        return PlanTransform(
            scale: s,
            origin: CGPoint(x: ox - CGFloat(bounds.minX) * s,
                            y: oy - CGFloat(bounds.minZ) * s))
    }
}

/// 販売図面を描く。製図の慣習に従う。
///
/// - 壁は太い実線。開口部では途切れる
/// - 窓は二重線
/// - 戸は開き弧。**幅 1.2m 超は両開き**（片開きで描くと扉 1 枚が開口幅ぶん
///   室内へ張り出して図が読めない。実測で 1736mm の開口があった）
/// - 寸法は mm
@available(iOS 17.0, *)
struct FloorPlanCanvas: View {

    let plan: FloorPlan
    /// 選択中の要素。訂正 UI が使う。
    var selectedFurniture: UUID?
    var selectedOpening: UUID?
    /// 訂正済みの要素（印を付ける）。
    var correctedIDs: Set<UUID> = []
    /// 要確認（confidence medium）を強調するか。
    var highlightMedium: Bool = true

    /// これを超える幅の戸は両開きとして描く。
    static let doubleDoorWidth = 1.2
    /// 壁の描画太さ（メートル）。実際の壁厚ではなく製図上の線幅。
    static let wallThickness = 0.09

    var body: some View {
        Canvas { ctx, size in
            let t = PlanTransform.fit(plan.bounds, in: size)
            drawFloor(ctx, t)
            drawFurniture(&ctx, t)
            drawWalls(ctx, t)
            drawOpenings(&ctx, t)
            drawDimensions(&ctx, t)
            drawRoomName(&ctx, t, size: size)
            drawNorth(&ctx, size: size)
        }
    }

    // MARK: 床と家具

    private func drawFloor(_ ctx: GraphicsContext, _ t: PlanTransform) {
        guard let poly = plan.polygon ?? plan.floorPolygon, poly.count >= 3 else { return }
        var path = Path()
        path.move(to: t.point(poly[0]))
        for p in poly.dropFirst() { path.addLine(to: t.point(p)) }
        path.closeSubpath()
        ctx.fill(path, with: .color(Color(white: 0.945)))
    }

    private func drawFurniture(_ ctx: inout GraphicsContext, _ t: PlanTransform) {
        for f in plan.furniture {
            var path = Path()
            let cs = f.corners
            path.move(to: t.point(cs[0]))
            for c in cs.dropFirst() { path.addLine(to: t.point(c)) }
            path.closeSubpath()

            let selected = f.id == selectedFurniture
            let needsCheck = highlightMedium && f.confidence == .medium
                && !correctedIDs.contains(f.id)
            ctx.fill(path, with: .color(selected ? Color.accentColor.opacity(0.28)
                                        : Color(white: 0.86).opacity(0.75)))
            ctx.stroke(path, with: .color(selected ? .accentColor
                                          : (needsCheck ? .orange : Color(white: 0.62))),
                       lineWidth: selected ? 3 : (needsCheck ? 2 : 1.2))

            let c = t.point(f.center)
            ctx.draw(Text(f.label).font(.system(size: 10))
                        .foregroundColor(Color(white: 0.42)), at: c)
        }
    }

    // MARK: 壁と開口

    private func drawWalls(_ ctx: GraphicsContext, _ t: PlanTransform) {
        let thick = CGFloat(FloorPlanCanvas.wallThickness) * t.scale
        var path = Path()
        for w in plan.walls {
            for (s, e) in w.solidSpans where e - s >= 0.02 {
                path.move(to: t.point(w.at(s)))
                path.addLine(to: t.point(w.at(e)))
            }
        }
        ctx.stroke(path, with: .color(Color(white: 0.10)),
                   style: StrokeStyle(lineWidth: thick, lineCap: .butt))
    }

    private func drawOpenings(_ ctx: inout GraphicsContext, _ t: PlanTransform) {
        let thick = CGFloat(FloorPlanCanvas.wallThickness) * t.scale
        let b = plan.bounds
        let center = SIMD2<Double>((b.minX + b.maxX) / 2, (b.minZ + b.maxZ) / 2)

        for w in plan.walls {
            let d = w.direction
            let normal = SIMD2<Double>(-d.y, d.x)
            for o in w.openings {
                let a = w.at(o.start), z = w.at(o.end)
                let selected = o.id == selectedOpening
                let needsCheck = highlightMedium && o.confidence == .medium
                    && !correctedIDs.contains(o.id)
                let tint: Color = selected ? .accentColor
                    : (needsCheck ? .orange : Color(white: 0.10))

                switch o.category {
                case .window:
                    // 窓は二重線。壁の芯から左右に少しずらす。
                    for off in [-0.022, 0.022] {
                        var p = Path()
                        p.move(to: t.point(a + normal * off))
                        p.addLine(to: t.point(z + normal * off))
                        ctx.stroke(p, with: .color(tint), lineWidth: selected ? 3.5 : 2)
                    }
                case .door, .opening:
                    // 開口を薄い線で塞ぐ
                    var gap = Path()
                    gap.move(to: t.point(a)); gap.addLine(to: t.point(z))
                    ctx.stroke(gap, with: .color(Color(white: 0.81)),
                               style: StrokeStyle(lineWidth: thick, lineCap: .butt))
                    if o.category == .door {
                        drawDoorLeaves(&ctx, t, a: a, z: z, normal: normal,
                                       roomCenter: center, width: o.width, tint: tint,
                                       emphasize: selected || needsCheck)
                    }
                }
            }
        }
    }

    private func drawDoorLeaves(_ ctx: inout GraphicsContext, _ t: PlanTransform,
                               a: SIMD2<Double>, z: SIMD2<Double>,
                               normal: SIMD2<Double>, roomCenter: SIMD2<Double>,
                               width: Double, tint: Color, emphasize: Bool) {
        let mid = (a + z) / 2
        let inward = simd_dot(normal, roomCenter - mid) > 0 ? normal : -normal
        // 広い開口は両開き。実際にもこの幅は引き違いや両開きで、片開きではない。
        let halves: [(SIMD2<Double>, Double)] =
            width > FloorPlanCanvas.doubleDoorWidth
            ? [(a, width / 2), (z, width / 2)]
            : [(a, width)]
        let far = halves.count == 2 ? mid : z

        for (hinge, leaf) in halves {
            let dir = simd_normalize(hinge == a ? (z - a) : (a - z))
            let end = hinge + inward * leaf
            var line = Path()
            line.move(to: t.point(hinge)); line.addLine(to: t.point(end))
            ctx.stroke(line, with: .color(tint), lineWidth: emphasize ? 2.6 : 1.8)

            // 弧。始点は扉の先端、終点は開口の中央（両開き）か反対端（片開き）。
            let target = halves.count == 2 ? hinge + dir * leaf : far
            var arc = Path()
            let c = t.point(hinge)
            let r = CGFloat(leaf) * t.scale
            let p0 = t.point(end), p1 = t.point(target)
            let a0 = atan2(p0.y - c.y, p0.x - c.x)
            let a1 = atan2(p1.y - c.y, p1.x - c.x)
            arc.addArc(center: c, radius: r,
                       startAngle: .radians(Double(a0)), endAngle: .radians(Double(a1)),
                       clockwise: shortWayIsClockwise(from: a0, to: a1))
            ctx.stroke(arc, with: .color(Color(white: 0.60)),
                       style: StrokeStyle(lineWidth: 1.1, dash: [5, 4]))
        }
    }

    /// 2 角の短い側を回る向き。長い側を回ると弧が部屋を横断する。
    private func shortWayIsClockwise(from a: CGFloat, to b: CGFloat) -> Bool {
        var d = Double(b - a)
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d < 0
    }

    // MARK: 寸法・室名・方位

    private func drawDimensions(_ ctx: inout GraphicsContext, _ t: PlanTransform) {
        let b = plan.bounds
        let center = SIMD2<Double>((b.minX + b.maxX) / 2, (b.minZ + b.maxZ) / 2)
        for w in plan.walls {
            let d = w.direction
            var normal = SIMD2<Double>(-d.y, d.x)
            let mid = (w.p0 + w.p1) / 2
            if simd_dot(mid - center, normal) < 0 { normal = -normal }
            let off = normal * 0.26

            var line = Path()
            line.move(to: t.point(w.p0 + off)); line.addLine(to: t.point(w.p1 + off))
            ctx.stroke(line, with: .color(Color(white: 0.63)), lineWidth: 1)
            for p in [w.p0, w.p1] {
                var tick = Path()
                tick.move(to: t.point(p + normal * 0.10))
                tick.addLine(to: t.point(p + normal * 0.34))
                ctx.stroke(tick, with: .color(Color(white: 0.63)), lineWidth: 1)
            }
            // **桁区切りを入れない。** SwiftUI の数値補間は地域設定で "3,135" に
            // なるが、建築図面の mm 表記にカンマは使わない。
            ctx.draw(Text(verbatim: String(Int((w.length * 1000).rounded())))
                        .font(.system(size: 11)).foregroundColor(Color(white: 0.25)),
                     at: t.point(mid + normal * 0.44))
        }
    }

    private func drawRoomName(_ ctx: inout GraphicsContext, _ t: PlanTransform,
                              size: CGSize) {
        let seat: SIMD2<Double>
        if let s = plan.sections.first { seat = s.center }
        else if let p = plan.polygon {
            seat = p.reduce(SIMD2<Double>(0, 0), +) / Double(p.count)
        } else {
            let b = plan.bounds
            seat = SIMD2((b.minX + b.maxX) / 2, (b.minZ + b.maxZ) / 2)
        }
        let c = t.point(seat)
        ctx.draw(Text(plan.roomName).font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(white: 0.10)),
                 at: CGPoint(x: c.x, y: c.y - 11))
        let tatami = String(format: "%.1f", FloorPlan.displayTatami(plan.area))
        ctx.draw(Text(verbatim: "約 \(tatami) 帖")
                    .font(.system(size: 15)).foregroundColor(Color(white: 0.10)),
                 at: CGPoint(x: c.x, y: c.y + 11))
    }

    private func drawNorth(_ ctx: inout GraphicsContext, size: CGSize) {
        // **取れていないときは描かない。** 嘘の方位を図に載せないため。
        guard let n0 = plan.north else { return }
        let n = simd_normalize(n0)
        let c = CGPoint(x: size.width - 34, y: 34)
        let r: CGFloat = 20
        let tip = CGPoint(x: c.x + CGFloat(n.x) * r, y: c.y + CGFloat(n.y) * r)
        let tail = CGPoint(x: c.x - CGFloat(n.x) * r * 0.7,
                           y: c.y - CGFloat(n.y) * r * 0.7)
        var shaft = Path(); shaft.move(to: tail); shaft.addLine(to: tip)
        ctx.stroke(shaft, with: .color(Color(white: 0.10)), lineWidth: 1.6)

        let perp = SIMD2<Double>(-n.y, n.x)
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - CGFloat(n.x) * 8 + CGFloat(perp.x) * 4,
                                 y: tip.y - CGFloat(n.y) * 8 + CGFloat(perp.y) * 4))
        head.addLine(to: CGPoint(x: tip.x - CGFloat(n.x) * 8 - CGFloat(perp.x) * 4,
                                 y: tip.y - CGFloat(n.y) * 8 - CGFloat(perp.y) * 4))
        head.closeSubpath()
        ctx.fill(head, with: .color(Color(white: 0.10)))
        ctx.draw(Text("N").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: 0.10)),
                 at: CGPoint(x: tip.x, y: tip.y + (n.y < 0 ? -11 : 13)))
    }
}
