import ARKit
import RealityKit
import Combine
import SwiftUI

/// ARView を SwiftUI に載せる。
///
/// ライブフィードバックは `debugOptions` の `.showSceneUnderstanding` 一行で得られる。
/// 自前で Metal を書かなくても LiDAR メッシュのワイヤーフレームが重なるので、
/// 「いま撮れているか」が撮影者に分かる。Scaniverse の赤い未取得表示に相当する
/// 本格的なカバレッジ可視化は後段（Tier 1）で作る。
struct ARViewContainer: UIViewRepresentable {
    let session: CaptureSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        view.debugOptions.insert(.showSceneUnderstanding)
        view.environment.sceneUnderstanding.options = []
        session.attach(to: view.session)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct CaptureView: View {
    @StateObject private var capture = CaptureSession()
    @State private var showProbe = false
    @State private var showLibrary = false
    /// RoomPlan と同居できるかの実測。撮影経路を作り直す前に潰しておく。
    @StateObject private var coexist = CoexistProbeBox()

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(session: capture).ignoresSafeArea()

            VStack {
                statsBar
                Spacer()
                controls
            }
            .padding()
        }
        .sheet(isPresented: $showProbe) {
            probeSheet
        }
        .sheet(isPresented: $showLibrary) {
            ScanListView()
        }
        .alert("エラー", isPresented: .constant(isFailed)) {
            Button("OK") { capture.acknowledge() }
        } message: {
            if case .failed(let message) = capture.state { Text(message) }
        }
    }


    private var isFailed: Bool {
        if case .failed = capture.state { return true }
        return false
    }

    // MARK: - 統計表示

    private var statsBar: some View {
        HStack(spacing: 16) {
            label("フレーム", "\(capture.acceptedCount)")
            label("経過", String(format: "%.0f 秒", capture.elapsed))
            label("実効", String(format: "%.1f fps", effectiveFPS))
            if capture.thermal != .nominal {
                label("温度", thermalText).foregroundStyle(.orange)
            }
            if !capture.lastRejection.isEmpty {
                label("棄却", capture.lastRejection).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showLibrary = true
            } label: {
                Label("過去のスキャン", systemImage: "square.stack.3d.up")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                showProbe = true
            } label: {
                // アイコンだけだと見つけられない。文字を添える。
                Label("診断", systemImage: "wrench.and.screwdriver")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var effectiveFPS: Double {
        capture.elapsed > 0.5 ? Double(capture.acceptedCount) / capture.elapsed : 0
    }

    private var thermalText: String {
        switch capture.thermal {
        case .nominal: return "normal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    private func label(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value)
        }
    }

    // MARK: - 操作

    @ViewBuilder
    private var controls: some View {
        switch capture.state {
        case .idle:
            recordButton(title: "録画開始", color: .red) { capture.startRecording() }
        case .recording:
            VStack(spacing: 8) {
                Text("外周を 3 パス（水平／天井／床）+ 中央をツアー導線どおりに 1 パス")
                    .font(.caption)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                recordButton(title: "停止", color: .white) { capture.stopRecording() }
            }
        case .finishing:
            VStack(spacing: 8) {
                // **離れると計算が止まる。** iOS はバックグラウンドのプロセスを
                // 約 30 秒で停止し、やがて終了させる。壁時計は進むので記録上は
                // 「異常に遅い焼き込み」に見え、実測で 3 回は成果物が出ないまま
                // プロセスが入れ替わっていた。
                Label("このまま画面を開いたままにしてください", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Text("他のアプリに切り替えると処理が止まり、やり直しになります")
                    .font(.caption2).foregroundStyle(.secondary)
                if let p = capture.bakeProgress {
                    ProgressView(value: p) {
                        Text("テクスチャを焼き込み中")
                    } currentValueLabel: {
                        Text("\(Int(p * 100))%").font(.system(.caption, design: .monospaced))
                    }
                    .frame(width: 260)
                } else {
                    ProgressView("書き出し中")
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .finished(let url):
            VStack(spacing: 8) {
                Text("保存しました").font(.headline)
                Text(url.lastPathComponent).font(.system(.caption, design: .monospaced))
                if let summary = capture.bakeSummary {
                    Text("mesh.glb: \(summary)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.green)
                }
                Text("ファイル App の「このiPad内」から Mac にコピーしてください")
                    .font(.caption2).foregroundStyle(.secondary)
                // **撮影の流れは撮影 → 焼き込み → 終了だけにする。**
                // 平面図の確認と訂正は「過去のスキャン」から開く。端末側で
                // 撮影直後に余計な処理を挟むと、焼き込みと資源を取り合う。
                Button("閉じる") { capture.acknowledge() }.buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .failed:
            EmptyView()
        }
    }

    private func recordButton(title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(width: 160, height: 52)
                .background(color, in: Capsule())
                .foregroundStyle(color == .red ? .white : .black)
        }
    }

    // MARK: - 実機診断

    private var probeSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(capture.probe?.summary ?? "取得中")
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if #available(iOS 17.0, *) {
                        Divider()
                        coexistSection
                    }
                }
                .padding()
            }
            .navigationTitle("実機診断")
            .toolbar {
                Button("閉じる") { showProbe = false }
            }
        }
    }
}


// MARK: - RoomPlan 同居の実測

/// `CoexistProbe` は iOS 17 以降にしか存在しないので、`@StateObject` に直接
/// 置けない（プロパティ宣言に availability を付けられない）。箱に包んで逃がす。
@MainActor
final class CoexistProbeBox: ObservableObject {
    @Published var status = "未実行"
    @Published var running = false
    private var probe: AnyObject?
    private var observers: [Any] = []

    @available(iOS 17.0, *)
    private var typed: CoexistProbe {
        if let p = probe as? CoexistProbe { return p }
        let p = CoexistProbe(duration: 30)
        probe = p
        // 箱の @Published へ橋渡しする
        observers.append(p.$status.sink { [weak self] in self?.status = $0 })
        observers.append(p.$running.sink { [weak self] in self?.running = $0 })
        return p
    }

    func run(withRoomPlan: Bool, reapplyDepth: Bool = false) {
        if #available(iOS 17.0, *) {
            typed.run(withRoomPlan: withRoomPlan, reapplyDepth: reapplyDepth)
        }
    }
}

extension CaptureView {
    @available(iOS 17.0, *)
    var coexistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RoomPlan 同居の実測").font(.headline)
            Text("30 秒ずつ 2 回。部屋を同じように回してください。\n"
                 + "測るのは所要時間ではなく採用フレーム数です。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("なしで 30 秒") { coexist.run(withRoomPlan: false) }
                    .buttonStyle(.borderedProminent)
                Button("ありで 30 秒") { coexist.run(withRoomPlan: true) }
                    .buttonStyle(.bordered)
                Button("あり＋深度再適用") {
                    coexist.run(withRoomPlan: true, reapplyDepth: true)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
            }
            .disabled(coexist.running)
            Text(coexist.status)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("結果は Documents/coexist_probe.json に残ります")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
