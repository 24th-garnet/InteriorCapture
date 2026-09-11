import QuickLook
import SwiftUI
import UIKit

/// 過去プロジェクト。撮影済みのスキャンを選んで 3D を見返す。
///
/// 3D は撮影直後に焼いた頂点カラーの `mesh.usdz` を Quick Look で開く
/// （**iOS の Quick Look は GLB を開けない**ので USDZ の方を使う）。
/// 高精度なテクスチャ版と間取り図はサーバ側（`recon/`）で作る。
struct ScanListView: View {

    @StateObject private var library = ScanLibrary()
    @Environment(\.dismiss) private var dismiss

    @State private var quickLookURL: URL?
    @State private var deleting: ScanLibrary.Scan?
    @State private var loadError: String?
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            Group {
                if library.scans.isEmpty {
                    // 配布対象は iOS 16 も含むので ContentUnavailableView は使えない。
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up.slash")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("プロジェクトがありません").font(.headline)
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
                            Text("3D は撮影直後に焼いた頂点カラーです。"
                                 + "高精度なテクスチャ版と間取り図は Mac 側で作ります。"
                                 + "ファイル App からバンドル（room-*.mdr）を取り出せます。")
                        }
                    }
                }
            }
            .navigationTitle("過去プロジェクト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            library.reload()
                        } label: {
                            Label("再読み込み", systemImage: "arrow.clockwise")
                        }
                        if !library.scans.isEmpty {
                            Divider()
                            Button(role: .destructive) {
                                confirmDeleteAll = true
                            } label: {
                                Label("すべて削除", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear { library.reload() }
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
            .alert("すべて削除しますか", isPresented: $confirmDeleteAll) {
                Button("削除", role: .destructive) { library.deleteAll() }
                Button("やめる", role: .cancel) {}
            } message: {
                Text(deleteAllMessage)
            }
            .alert("開けません", isPresented: .constant(loadError != nil)) {
                Button("OK") { loadError = nil }
            } message: {
                Text(loadError ?? "")
            }
        }
    }


    // MARK: 文面

    /// 一括削除の確認文。
    ///
    /// **退避の確認を促すのが目的。** バンドルには撮影の生データ（フレーム・
    /// 深度・ポーズ）が入っていて、高精度なテクスチャと間取り図はここからしか
    /// 作れない。端末側の 3D は頂点カラーで、焼き直しには元データが要る。
    ///
    /// 式のままビューに置くと型チェックが通らなかったので切り出してある。
    private var deleteAllMessage: String {
        let size = library.totalBytes
        let amount = size > 0
            ? "（" + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) + "）"
            : ""
        return "\(library.scans.count) 件\(amount)を消します。取り消せません。\n\n"
            + "バンドルには撮影の生データが入っています。高精度なテクスチャと"
            + "間取り図はここからしか作れないので、Mac へ退避したことを"
            + "確認してから削除してください。"
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
                      + (scan.vertexColorSec.map { String(format: "　頂点色 %.1f 秒", $0) } ?? "")
                      + (scan.bakeThermal.map { "　温度 \($0)" } ?? ""))
            } else if let v = scan.vertexColorSec {
                label(String(format: "3D 生成 %.2f 秒", v)
                      + (scan.vertexColorUnfilled.map {
                          String(format: "　未撮影 %.0f%%", $0 * 100) } ?? ""))
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
                if scan.hasFixes { badge("訂正済", .green) }
                if let c = scan.bakeConfiguration, c != "Release" { badge(c, .orange) }
                if let x = scan.bakeSlowdown, x > BuildInfo.Metrics.slowdownAlarm {
                    badge(String(format: "展開 %.1f 倍", x), .red)
                }
            }
            HStack(spacing: 10) {

                Button {
                    if scan.hasUSDZ { quickLookURL = scan.usdzURL }
                    else { loadError = "このスキャンには mesh.usdz がありません（焼き込みが未完了です）" }
                } label: {
                    Label("3D", systemImage: "cube")
                }
                .buttonStyle(.bordered)
                .disabled(!scan.hasUSDZ)

                if scan.hasVertexColorUSDZ {
                    Button {
                        quickLookURL = scan.vertexColorUSDZURL
                    } label: {
                        Label("3D 頂点色", systemImage: "cube.transparent")
                    }
                    .buttonStyle(.bordered)
                }

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
