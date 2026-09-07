import Foundation
import RoomPlan
import simd

/// `CapturedRoom` から販売図面用の間取りを作る。
///
/// なぜ端末側で作れるのか
/// -------------------
/// `CapturedRoom` はすでにパラメトリック（壁 1 枚 = 幅 + 4x4 変換）なので、
/// **メッシュも画像も要らない**。焼き込み（実測 15〜34 秒）を待たずに、
/// `RoomBuilder` が返った直後に図を出せる。
///
/// Python 側（`recon/mdr2colmap/roomplan.py`）との違いは入力だけで、規則は同じ。
/// あちらは `room.json` を読むので列優先 16 要素の転置が必要だが、ここでは
/// `simd_float4x4` が直接来るため、**座標規約を取り違える余地がない**。
///
/// 上方向は Y
/// ---------
/// ARKit も RoomPlan も Y-up。真上から見るとは **Y を捨てて X-Z 平面に置く**こと。
/// 描画では +Z を画面下に取る（詳細は `FloorPlanCanvas`）。
@available(iOS 17.0, *)
struct FloorPlan {

    // MARK: 表示規則（不動産の表示に関する公正競争規約）

    /// 畳 1 枚あたりの面積 1.62 m2。施行規則は「畳 1 枚が 1.62 m2 以上ある」
    /// 意味で用いる定めなので、帖数は**切り捨て**なければならない。
    static let tatamiArea: Double = 1.62

    /// 面積表示。小数第 2 位以下を切り捨てる。
    /// 四捨五入・切り上げは実際より広く見せるので使えない。
    static func displayArea(_ m2: Double) -> Double { (m2 * 100).rounded(.down) / 100 }

    /// 帖数表示。小数第 1 位以下を切り捨てる。
    static func displayTatami(_ m2: Double) -> Double {
        (m2 / tatamiArea * 10).rounded(.down) / 10
    }

    // MARK: 要素

    struct Opening: Identifiable {
        let id: UUID
        var category: Category
        /// 親の壁に沿った位置（壁の始点からの距離、メートル）。
        let start: Double
        let end: Double
        let height: Double
        /// 開口の下端の高さ（床から）。
        let sill: Double
        let confidence: RoomPlan.CapturedRoom.Confidence
        /// 親の壁の識別子。
        let wallID: UUID

        enum Category: String, CaseIterable {
            case door, window, opening
            var label: String {
                switch self {
                case .door: return "戸"
                case .window: return "窓"
                case .opening: return "開口"
                }
            }
        }

        var width: Double { end - start }
    }

    struct Wall: Identifiable {
        let id: UUID
        /// 平面上の線分（X, Z）。
        let p0: SIMD2<Double>
        let p1: SIMD2<Double>
        let height: Double
        let confidence: RoomPlan.CapturedRoom.Confidence
        var openings: [Opening] = []

        var length: Double { simd_length(p1 - p0) }

        var direction: SIMD2<Double> {
            let d = p1 - p0
            let n = simd_length(d)
            return n > 1e-9 ? d / n : SIMD2(1, 0)
        }

        func at(_ t: Double) -> SIMD2<Double> { p0 + direction * t }

        /// 開口を除いた実体部分の区間。壁の線をここで途切れさせる。
        var solidSpans: [(Double, Double)] {
            let spans = openings
                .map { (max(0, min($0.start, $0.end)), min(length, max($0.start, $0.end))) }
                .sorted { $0.0 < $1.0 }
            var out: [(Double, Double)] = []
            var cursor = 0.0
            for (s, e) in spans {
                if s > cursor { out.append((cursor, s)) }
                cursor = max(cursor, e)
            }
            if cursor < length { out.append((cursor, length)) }
            return out
        }
    }

    struct Furniture: Identifiable {
        let id: UUID
        let category: RoomPlan.CapturedRoom.Object.Category
        /// 平面上の中心（X, Z）。訂正を含む。
        var center: SIMD2<Double>
        /// 幅・奥行の半径と、平面上の向き。
        let halfWidth: Double
        let halfDepth: Double
        let yaw: Double
        let height: Double
        let confidence: RoomPlan.CapturedRoom.Confidence

        /// 平面上の 4 隅。回転を保つため矩形は 4 点で持つ。
        var corners: [SIMD2<Double>] {
            let c = cos(yaw), s = sin(yaw)
            let ex = SIMD2(c, s), ez = SIMD2(-s, c)
            return [
                center - ex * halfWidth - ez * halfDepth,
                center + ex * halfWidth - ez * halfDepth,
                center + ex * halfWidth + ez * halfDepth,
                center - ex * halfWidth + ez * halfDepth,
            ]
        }

        var label: String { FloorPlan.name(of: category) }
    }

    // MARK: 間取り

    var walls: [Wall] = []
    var furniture: [Furniture] = []
    var sections: [(label: String, center: SIMD2<Double>)] = []
    var floorY: Double = 0
    var ceilingY: Double = 0
    /// 平面上の北（X, Z の単位ベクトル）。取れていなければ nil。
    var north: SIMD2<Double>?

    var ceilingHeight: Double { ceilingY - floorY }

    var openings: [Opening] { walls.flatMap { $0.openings } }

    func openings(_ category: Opening.Category) -> [Opening] {
        openings.filter { $0.category == category }
    }

    /// 室名。区画が取れなければ「居室」。
    var roomName: String {
        let names = sections.map { FloorPlan.sectionName($0.label) }
        return names.isEmpty ? "居室" : names.joined(separator: "・")
    }

    /// 壁を繋いだ閉多角形。閉じなければ nil。
    ///
    /// 壁は順序不定で返るので、端点が近いものを辿って並べ直す。
    var polygon: [SIMD2<Double>]? {
        guard walls.count >= 3 else { return nil }
        var remaining = Array(walls.dropFirst())
        var chain = [walls[0].p0, walls[0].p1]
        let tol = 0.35            // RoomPlan の壁は端点がぴったり合わない
        while !remaining.isEmpty {
            let tail = chain[chain.count - 1]
            var best: (index: Int, flip: Bool, d: Double)?
            for (i, w) in remaining.enumerated() {
                for (pt, flip) in [(w.p0, false), (w.p1, true)] {
                    let d = simd_length(pt - tail)
                    if d < tol && (best == nil || d < best!.d) {
                        best = (i, flip, d)
                    }
                }
            }
            guard let hit = best else { return nil }
            let w = remaining.remove(at: hit.index)
            chain.append(hit.flip ? w.p0 : w.p1)
        }
        guard simd_length(chain[chain.count - 1] - chain[0]) <= tol else { return nil }
        return Array(chain.dropLast())
    }

    enum AreaSource: String { case walls = "壁", floor = "床外形", bounds = "外接矩形" }

    /// 床外形（`floors[].polygonCorners`）。**壁が閉じないときの代替。**
    ///
    /// 照合には使えない。実測で床の多角形の隅は壁ループの隅と完全に一致し、
    /// RoomPlan が床を壁から導出していることが分かっている。
    var floorPolygon: [SIMD2<Double>]?

    var areaSource: AreaSource {
        if polygon != nil { return .walls }
        if floorPolygon != nil { return .floor }
        return .bounds
    }

    /// 内法面積。**外接矩形は必ず過大**なので最後の手段。
    var area: Double {
        if let p = polygon { return FloorPlan.polygonArea(p) }
        if let p = floorPolygon { return FloorPlan.polygonArea(p) }
        let b = bounds
        return (b.maxX - b.minX) * (b.maxZ - b.minZ)
    }

    var bounds: (minX: Double, minZ: Double, maxX: Double, maxZ: Double) {
        var lo = SIMD2<Double>(.infinity, .infinity)
        var hi = SIMD2<Double>(-.infinity, -.infinity)
        for w in walls {
            lo = simd_min(lo, simd_min(w.p0, w.p1))
            hi = simd_max(hi, simd_max(w.p0, w.p1))
        }
        if walls.isEmpty { return (0, 0, 1, 1) }
        return (lo.x, lo.y, hi.x, hi.y)
    }

    static func polygonArea(_ p: [SIMD2<Double>]) -> Double {
        guard p.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    // MARK: 名前

    /// RoomPlan の section ラベルを販売図面の室名にする。
    /// 洋室 / 和室 の区別は床仕上げで決まるが RoomPlan は返さないので、
    /// `bedroom` は一律「洋室」にする。畳敷きなら人が直す。
    static func sectionName(_ label: String) -> String {
        switch label {
        case "bedroom": return "洋室"
        case "livingRoom", "livingArea": return "リビング"
        case "diningRoom", "diningArea": return "ダイニング"
        case "kitchen": return "キッチン"
        case "bathroom": return "浴室"
        case "office": return "書斎"
        case "familyRoom": return "居間"
        case "storage": return "納戸"
        case "hallway": return "廊下"
        case "laundryRoom": return "洗濯室"
        default: return label
        }
    }

    static func name(of c: RoomPlan.CapturedRoom.Object.Category) -> String {
        switch c {
        case .storage: return "収納"
        case .table: return "テーブル"
        case .chair: return "椅子"
        case .bed: return "ベッド"
        case .sofa: return "ソファ"
        case .television: return "テレビ"
        case .refrigerator: return "冷蔵庫"
        case .stove: return "コンロ"
        case .sink: return "流し"
        case .toilet: return "便器"
        case .bathtub: return "浴槽"
        case .washerDryer: return "洗濯機"
        case .oven: return "オーブン"
        case .dishwasher: return "食洗機"
        case .fireplace: return "暖炉"
        case .stairs: return "階段"
        default: return "家具"
        }
    }

    // MARK: 構築

    /// 開口を親の壁に割り当てる際の許容距離。これを超える場合は最も近い壁へ。
    static let openingSnapTolerance = 0.35

    /// `CapturedRoom` から間取りを作る。`corrections` は人手の訂正。
    init(room: CapturedRoom, corrections: PlanCorrections = .init(),
         north: SIMD2<Double>? = nil) {
        self.north = north

        // 壁
        var walls: [Wall] = []
        for s in room.walls {
            let (p0, p1, _) = FloorPlan.segment(s)
            walls.append(Wall(id: s.identifier, p0: p0, p1: p1,
                              height: Double(s.dimensions.y), confidence: s.confidence))
        }
        let floorCandidates = room.walls.map {
            Double($0.transform.columns.3.y) - Double($0.dimensions.y) / 2
        }
        floorY = FloorPlan.median(floorCandidates)
        ceilingY = floorY + (room.walls.map { Double($0.dimensions.y) }.max() ?? 0)

        // 開口。**種別の判定は RoomPlan が行う。** ここは読むだけで、
        // 誤りは `corrections` で人が直す（実測で掃き出し窓が door になっていた）。
        for s in room.doors + room.windows + room.openings {
            let (p0, p1, center) = FloorPlan.segment(s)
            let mid = (p0 + p1) / 2
            var parentIndex: Int?
            if let pid = s.parentIdentifier,
               let i = walls.firstIndex(where: { $0.id == pid }),
               FloorPlan.distance(from: mid, to: walls[i]) <= FloorPlan.openingSnapTolerance {
                parentIndex = i
            } else {
                // 親が無い / 離れている場合は最も近い壁へ。落とすと開口が図から消える。
                parentIndex = walls.indices.min {
                    FloorPlan.distance(from: mid, to: walls[$0])
                        < FloorPlan.distance(from: mid, to: walls[$1])
                }
            }
            guard let i = parentIndex else { continue }
            let t0 = FloorPlan.project(mid: p0, on: walls[i])
            let t1 = FloorPlan.project(mid: p1, on: walls[i])
            let h = Double(s.dimensions.y)
            let base = FloorPlan.category(of: s.category)
            let cat = corrections.openings[s.identifier.uuidString]
                .flatMap { Opening.Category(rawValue: $0) } ?? base
            walls[i].openings.append(Opening(
                id: s.identifier, category: cat,
                start: min(t0, t1), end: max(t0, t1),
                height: h, sill: Double(center.y) - h / 2 - floorY,
                confidence: s.confidence, wallID: walls[i].id))
        }
        self.walls = walls

        // 家具。箱の位置の訂正を足す（実測で椅子の箱が Z 方向に 35cm ずれていた）。
        for o in room.objects {
            let t = o.transform
            var c = SIMD2<Double>(Double(t.columns.3.x), Double(t.columns.3.z))
            if let fix = corrections.boxes[o.identifier.uuidString] {
                c += SIMD2(Double(fix.x), Double(fix.z))
            }
            let ex = t.columns.0
            furniture.append(Furniture(
                id: o.identifier, category: o.category, center: c,
                halfWidth: Double(o.dimensions.x) / 2,
                halfDepth: Double(o.dimensions.z) / 2,
                yaw: atan2(Double(ex.z), Double(ex.x)),
                height: Double(o.dimensions.y), confidence: o.confidence))
        }

        sections = room.sections.map {
            (label: FloorPlan.label(of: $0.label),
             center: SIMD2(Double($0.center.x), Double($0.center.z)))
        }

        if let f = room.floors.first, !f.polygonCorners.isEmpty {
            let t = f.transform
            floorPolygon = f.polygonCorners.map { p -> SIMD2<Double> in
                let w = t * SIMD4<Float>(p.x, p.y, p.z, 1)
                return SIMD2(Double(w.x), Double(w.z))
            }
        }
    }

    // MARK: 小道具

    /// 面を平面上の線分にする。列 0 = 幅方向、列 3 = 中心。
    static func segment(_ s: CapturedRoom.Surface)
        -> (SIMD2<Double>, SIMD2<Double>, SIMD3<Double>) {
        let t = s.transform
        let c = SIMD3<Double>(Double(t.columns.3.x), Double(t.columns.3.y),
                              Double(t.columns.3.z))
        var d = SIMD2<Double>(Double(t.columns.0.x), Double(t.columns.0.z))
        let n = simd_length(d)
        d = n > 1e-9 ? d / n : SIMD2(1, 0)
        let half = Double(s.dimensions.x) / 2
        let c2 = SIMD2(c.x, c.z)
        return (c2 - d * half, c2 + d * half, c)
    }

    static func project(mid p: SIMD2<Double>, on w: Wall) -> Double {
        simd_dot(p - w.p0, w.direction)
    }

    /// 点から壁の線分までの距離。
    static func distance(from p: SIMD2<Double>, to w: Wall) -> Double {
        let seg = w.p1 - w.p0
        let l2 = simd_dot(seg, seg)
        guard l2 > 1e-12 else { return simd_length(p - w.p0) }
        let t = max(0, min(1, simd_dot(p - w.p0, seg) / l2))
        return simd_length(p - (w.p0 + seg * t))
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2]
            : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func category(of c: CapturedRoom.Surface.Category) -> Opening.Category {
        switch c {
        case .door: return .door
        case .window: return .window
        case .opening: return .opening
        default: return .opening
        }
    }

    static func label(of l: CapturedRoom.Section.Label) -> String {
        // Section.Label は文字列化できるが列挙の名前がそのまま出る。
        String(describing: l)
    }
}
