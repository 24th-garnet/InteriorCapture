import ARKit
import RealityKit
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
                showProbe = true
            } label: {
                Image(systemName: "info.circle")
            }
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
            ProgressView("書き出し中")
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .finished(let url):
            VStack(spacing: 8) {
                Text("保存しました").font(.headline)
                Text(url.lastPathComponent).font(.system(.caption, design: .monospaced))
                Text("ファイル App の「このiPad内」から Mac にコピーしてください")
                    .font(.caption2).foregroundStyle(.secondary)
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
                Text(capture.probe?.summary ?? "取得中")
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("実機診断")
            .toolbar {
                Button("閉じる") { showProbe = false }
            }
        }
    }
}
