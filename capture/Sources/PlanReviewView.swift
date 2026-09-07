import RoomPlan
import SwiftUI
import simd

/// 撮影直後に、その場で平面図を確認して直す画面。
///
/// なぜ端末で直すのか
/// ----------------
/// 実測で自動補正が二度とも誤答した（`PlanCorrections` を参照）。直せるのは
/// 人だけで、その人は部屋の中に立っている。**カーテンの前で「これは窓」と
/// 押すのが、写真に投影して調べるより速く確実。**
///
/// 何を直すか
/// ---------
/// RoomPlan の `confidence` が `medium` の要素だけを作業リストに出す。
/// 実測（room-33d49373）では箱 2 件（椅子・ベッド）と開口 2 件で、
/// うち椅子の箱が 35cm ずれ、開口 1 件が窓を戸と誤っていた。
/// 「全部確認」ではなく「4 件確認」で済む。
@available(iOS 17.0, *)
struct PlanReviewView: View {

    let room: CapturedRoom
    let bundleURL: URL?
    let north: SIMD2<Double>?

    @Environment(\.dismiss) private var dismiss

    @State private var corrections = PlanCorrections()
    @State private var selectedFurniture: UUID?
    @State private var selectedOpening: UUID?
    @State private var checked: Set<UUID> = []
    @State private var transform = PlanTransform(scale: 1, origin: .zero)
    @State private var dragOrigin: SIMD2<Double>?
    @State private var saved = false

    /// 1 回のボタンで動かす量（メートル）。指のドラッグでは細かく決められない。
    private static let nudge = 0.05

    private var plan: FloorPlan {
        FloorPlan(room: room, corrections: corrections, north: north)
    }

    /// 要確認の残り。訂正したか「確認済み」を押したものは外れる。
    private var pending: [PendingItem] {
        var out: [PendingItem] = []
        for o in plan.openings where o.confidence == .medium {
            if checked.contains(o.id) || corrections.openings[o.id.uuidString] != nil { continue }
            out.append(.opening(o))
        }
        for f in plan.furniture where f.confidence == .medium {
            if checked.contains(f.id) || corrections.boxes[f.id.uuidString] != nil { continue }
            out.append(.furniture(f))
        }
        return out
    }

    enum PendingItem: Identifiable {
        case opening(FloorPlan.Opening)
        case furniture(FloorPlan.Furniture)

        var id: UUID {
            switch self {
            case .opening(let o): return o.id
            case .furniture(let f): return f.id
            }
        }

        var title: String {
            switch self {
            case .opening(let o):
                return "\(o.category.label)　幅 " + String(Int((o.width * 1000).rounded())) + " mm"
            case .furniture(let f):
                return f.label + "　" + String(Int((f.halfWidth * 2000).rounded()))
                    + "×" + String(Int((f.halfDepth * 2000).rounded())) + " mm"
            }
        }

        var hint: String {
            switch self {
            case .opening: return "戸か窓か"
            case .furniture: return "箱の位置"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                canvas
                Divider()
                controls
            }
            .navigationTitle("平面図の確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saved ? "保存済み" : "保存") { save() }
                        .disabled(bundleURL == nil)
                }
            }
            .onAppear {
                if let url = bundleURL { corrections = PlanCorrections.load(from: url) }
            }
        }
    }

    // MARK: 見出し

    private var header: some View {
        let p = plan
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(p.roomName)　約 "
                     + String(format: "%.2f", FloorPlan.displayArea(p.area)) + " m²"
                     + "（約 " + String(format: "%.1f", FloorPlan.displayTatami(p.area)) + " 帖）")
                    .font(.headline)
                Text(verbatim: "内法実測　天井高 "
                     + String(Int((p.ceilingHeight * 1000).rounded())) + " mm"
                     + "　戸 \(p.openings(.door).count)　窓 \(p.openings(.window).count)"
                     + "　寸法 mm" + (p.north == nil ? "　方位未計測" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 1) {
                Text("\(pending.count)").font(.title3.monospacedDigit())
                    .foregroundStyle(pending.isEmpty ? .green : .orange)
                Text("要確認").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: 図

    private var canvas: some View {
        GeometryReader { geo in
            FloorPlanCanvas(plan: plan,
                            selectedFurniture: selectedFurniture,
                            selectedOpening: selectedOpening,
                            correctedIDs: correctedIDs)
                .background(Color(white: 0.99))
                .onAppear { transform = PlanTransform.fit(plan.bounds, in: geo.size) }
                .onChange(of: geo.size) { _, size in
                    transform = PlanTransform.fit(plan.bounds, in: size)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in handleDrag(g) }
                        .onEnded { _ in dragOrigin = nil }
                )
        }
        .frame(minHeight: 320)
    }

    private var correctedIDs: Set<UUID> {
        var out = checked
        for k in corrections.openings.keys { if let u = UUID(uuidString: k) { out.insert(u) } }
        for k in corrections.boxes.keys { if let u = UUID(uuidString: k) { out.insert(u) } }
        return out
    }

    /// 指を置いたら選び、動かしたら箱を動かす。開口は選ぶだけ（種別はボタンで）。
    private func handleDrag(_ g: DragGesture.Value) {
        let world = transform.world(g.startLocation)
        if dragOrigin == nil {
            dragOrigin = world
            select(at: world)
        }
        guard let id = selectedFurniture, let start = dragOrigin else { return }
        let now = transform.world(g.location)
        let d = now - start
        // 既にある補正に足す。押し直しても累積しないよう、基準は指を置いた位置。
        var base = corrections.boxes[id.uuidString] ?? .init()
        base = PlanCorrections.Offset(dx: base.dx + d.x, dy: base.dy, dz: base.dz + d.y)
        corrections.boxes[id.uuidString] = base
        dragOrigin = now
        saved = false
    }

    private func select(at world: SIMD2<Double>) {
        let p = plan
        // 家具は矩形の内側。近い順に見る。
        if let hit = p.furniture.first(where: { contains($0, world) }) {
            selectedFurniture = hit.id
            selectedOpening = nil
            return
        }
        // 開口は線分の近く（30cm 以内）。
        var best: (UUID, Double)?
        for w in p.walls {
            for o in w.openings {
                let mid = w.at((o.start + o.end) / 2)
                let d = simd_length(mid - world)
                if d < 0.35 && (best == nil || d < best!.1) { best = (o.id, d) }
            }
        }
        if let hit = best {
            selectedOpening = hit.0
            selectedFurniture = nil
        } else {
            selectedFurniture = nil
            selectedOpening = nil
        }
    }

    private func contains(_ f: FloorPlan.Furniture, _ p: SIMD2<Double>) -> Bool {
        let c = cos(f.yaw), s = sin(f.yaw)
        let d = p - f.center
        let localX = d.x * c + d.y * s
        let localZ = -d.x * s + d.y * c
        return abs(localX) <= f.halfWidth && abs(localZ) <= f.halfDepth
    }

    // MARK: 操作

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if let id = selectedOpening, let o = plan.openings.first(where: { $0.id == id }) {
                openingControls(o)
            } else if let id = selectedFurniture,
                      let f = plan.furniture.first(where: { $0.id == id }) {
                furnitureControls(f)
            } else if pending.isEmpty {
                Label("要確認はありません", systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(.green)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            } else {
                Text("要確認を選んでください").font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            if !pending.isEmpty { pendingList }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func openingControls(_ o: FloorPlan.Opening) -> some View {
        VStack(spacing: 6) {
            Text(verbatim: "幅 " + String(Int((o.width * 1000).rounded())) + " mm　"
                 + "高 " + String(Int((o.height * 1000).rounded())) + " mm　"
                 + "下端 " + String(Int((o.sill * 1000).rounded())) + " mm")
                .font(.caption).foregroundStyle(.secondary)
            Picker("種別", selection: Binding(
                get: { o.category },
                set: { setCategory(o, $0) }
            )) {
                ForEach(FloorPlan.Opening.Category.allCases, id: \.self) { c in
                    Text(c.label).tag(c)
                }
            }
            .pickerStyle(.segmented)
            Button("この 1 件は確認済み") { checked.insert(o.id); selectedOpening = nil }
                .font(.caption)
        }
    }

    private func furnitureControls(_ f: FloorPlan.Furniture) -> some View {
        let fix = corrections.boxes[f.id.uuidString] ?? .init()
        return VStack(spacing: 6) {
            Text(verbatim: f.label + "　補正 X " + String(Int((fix.dx * 1000).rounded()))
                 + " mm / Z " + String(Int((fix.dz * 1000).rounded())) + " mm")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                nudgeButton("chevron.up", dx: 0, dz: -PlanReviewView.nudge, id: f.id)
                nudgeButton("chevron.down", dx: 0, dz: PlanReviewView.nudge, id: f.id)
                nudgeButton("chevron.left", dx: -PlanReviewView.nudge, dz: 0, id: f.id)
                nudgeButton("chevron.right", dx: PlanReviewView.nudge, dz: 0, id: f.id)
                Button("戻す") {
                    corrections.boxes.removeValue(forKey: f.id.uuidString); saved = false
                }.font(.caption)
                Button("確認済み") { checked.insert(f.id); selectedFurniture = nil }
                    .font(.caption)
            }
            Text("図の上を指で動かしても直せます").font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func nudgeButton(_ icon: String, dx: Double, dz: Double, id: UUID) -> some View {
        Button {
            var base = corrections.boxes[id.uuidString] ?? .init()
            base = PlanCorrections.Offset(dx: base.dx + dx, dy: base.dy, dz: base.dz + dz)
            corrections.boxes[id.uuidString] = base
            saved = false
        } label: {
            Image(systemName: icon).frame(width: 34, height: 30)
        }
        .buttonStyle(.bordered)
    }

    private var pendingList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pending) { item in
                    Button {
                        switch item {
                        case .opening(let o):
                            selectedOpening = o.id; selectedFurniture = nil
                        case .furniture(let f):
                            selectedFurniture = f.id; selectedOpening = nil
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.caption).lineLimit(1)
                            Text(item.hint).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.orange.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.orange.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func setCategory(_ o: FloorPlan.Opening, _ c: FloorPlan.Opening.Category) {
        corrections.openings[o.id.uuidString] = c.rawValue
        saved = false
    }

    private func save() {
        guard let url = bundleURL else { return }
        let note = "端末で人手訂正。RoomPlan の confidence medium を実物と見比べて直した値。"
        saved = corrections.write(to: url, note: note)
    }
}
