import QuickLook
import SwiftUI
import UIKit

/// 過去のスキャンを選んで開く。
///
/// 平面図は `room.json` だけで作れるので、撮り直しに来なくても後から確認・訂正
/// できる。3D は焼き込み時の `mesh.usdz` を Quick Look で開く
/// （**iOS の Quick Look は GLB を開けない**ので USDZ の方を使う）。
struct ScanListView: View {

    @StateObject private var library = ScanLibrary()
    @Environment(\.dismiss) private var dismiss

    @State private var planScan: ScanLibrary.Scan?
    @State private var quickLookURL: URL?
    @State private var deleting: ScanLibrary.Scan?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if library.scans.isEmpty {
                    // 配布対象は iOS 16 も含むので ContentUnavailableView は使えない。
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up.slash")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("スキャンがありません").font(.headline)
                        Text("撮影すると Documents に room-*.mdr が作られます")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        Section {
                            ForEach(library.scans) { scan in
                                row(scan)
                            }
                        } footer: {
                            Text("平面図は room.json だけで作れます。3D は焼き込み時の "
                                 + "mesh.usdz を開きます。")
                        }
                    }
                }
            }
            .navigationTitle("過去のスキャン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        library.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear { library.reload() }
            .sheet(item: $planScan) { scan in
                if #available(iOS 17.0, *) {
                    planSheet(scan)
                } else {
                    Text("平面図の表示には iOS 17 以降が必要です").padding()
                }
            }
            .sheet(item: $quickLookURL) { url in
                QuickLookView(url: url)
            }
            .alert("削除しますか", isPresented: .constant(deleting != nil)) {
                Button("削除", role: .destructive) {
                    if let s = deleting { library.delete(s) }
                    deleting = nil
                }
                Button("やめる", role: .cancel) { deleting = nil }
            } message: {
                Text("\(deleting?.title ?? "") を消します。取り消せません。")
            }
            .alert("開けません", isPresented: .constant(loadError != nil)) {
                Button("OK") { loadError = nil }
            } message: {
                Text(loadError ?? "")
            }
        }
    }

    @available(iOS 17.0, *)
    @ViewBuilder
    private func planSheet(_ scan: ScanLibrary.Scan) -> some View {
        if let room = try? scan.loadRoom() {
            PlanReviewView(room: room, bundleURL: scan.url, north: scan.north)
        } else {
            VStack(spacing: 10) {
                Text("room.json を読めませんでした").font(.headline)
                Text(scan.name).font(.system(.caption, design: .monospaced))
            }.padding()
        }
    }

    // MARK: 行

    private func row(_ scan: ScanLibrary.Scan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(scan.title).font(.system(.body, design: .monospaced))
                Spacer()
                if let d = scan.createdAt {
                    Text(d, format: .dateTime.month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let e = scan.bakeElapsedSec, let u = scan.bakeUnwrapSec {
                label(String(format: "焼き込み %.1f 秒（展開 %.1f）", e, u)
                      + (scan.bakeThermal.map { "　温度 \($0)" } ?? ""))
            }
            HStack(spacing: 8) {
                if let n = scan.frameCount {
                    label("\(n) フレーム")
                }
                if let s = scan.durationSec {
                    label(String(format: "%.0f 秒", s))
                }
                if let b = scan.byteSize {
                    label(ByteCountFormatter.string(fromByteCount: b, countStyle: .file))
                } else {
                    label("計測中")
                }
                if scan.north != nil { badge("方位", .blue) }
                if scan.hasFixes { badge("訂正済", .green) }
                if let c = scan.bakeConfiguration, c != "Release" { badge(c, .orange) }
                if let x = scan.bakeSlowdown, x > BuildInfo.Metrics.slowdownAlarm {
                    badge(String(format: "展開 %.1f 倍", x), .red)
                }
            }
            HStack(spacing: 10) {
                Button {
                    if scan.hasRoom { planScan = scan }
                    else { loadError = "このスキャンには room.json がありません（RoomPlan を含む撮影が必要です）" }
                } label: {
                    Label("平面図", systemImage: "square.dashed")
                }
                .buttonStyle(.bordered)
                .disabled(!scan.hasRoom)

                Button {
                    if scan.hasUSDZ { quickLookURL = scan.usdzURL }
                    else { loadError = "このスキャンには mesh.usdz がありません（焼き込みが未完了です）" }
                } label: {
                    Label("3D", systemImage: "cube")
                }
                .buttonStyle(.bordered)
                .disabled(!scan.hasUSDZ)

                Spacer()
                Button(role: .destructive) { deleting = scan } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.5), lineWidth: 1))
            .foregroundStyle(color)
    }
}

/// USDZ を Quick Look で開く。**GLB は iOS の Quick Look が扱えない。**
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ c: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// `sheet(item:)` に URL を渡すための最小の `Identifiable`。
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
