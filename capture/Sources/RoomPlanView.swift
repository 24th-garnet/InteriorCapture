import RoomPlan
import SwiftUI

/// RoomPlan の撮影画面。
///
/// `RoomCaptureView` は Apple 純正のガイド付き UI（進捗・コーチング表示つき）で、
/// 自前の ARView より撮影者にとって分かりやすい。
@available(iOS 16.0, *)
struct RoomPlanCaptureViewContainer: UIViewRepresentable {
    let capture: RoomPlanCapture

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        // captureSession は get-only。ビューが作ったセッションを受け取って delegate を張る。
        capture.attach(to: view.captureSession)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

@available(iOS 16.0, *)
struct RoomPlanView: View {
    @StateObject private var capture = RoomPlanCapture()

    var body: some View {
        ZStack(alignment: .bottom) {
            if capture.state != .unsupported {
                RoomPlanCaptureViewContainer(capture: capture).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack {
                if capture.state == .scanning {
                    HStack(spacing: 16) {
                        stat("壁", capture.wallCount)
                        stat("物体", capture.objectCount)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer()
                controls
            }
            .padding()
        }
    }

    private func stat(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text("\(n)")
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch capture.state {
        case .unsupported:
            Text("この端末は RoomPlan に対応していません")
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .idle:
            button("RoomPlan スキャン開始", .red) { capture.start() }
        case .scanning:
            VStack(spacing: 8) {
                Text("壁沿いをゆっくり歩き、ドアと窓を正面から捉える")
                    .font(.caption)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                button("停止", .white) { capture.stop() }
            }
        case .processing:
            ProgressView("構造を解析中")
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .finished(let url):
            VStack(spacing: 8) {
                Text("保存しました").font(.headline)
                Text(url.lastPathComponent).font(.system(.caption, design: .monospaced))
                Text("room.usdz と room.json を書き出しました")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("閉じる") { capture.acknowledge() }.buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .failed(let message):
            VStack(spacing: 8) {
                Text("エラー").font(.headline)
                Text(message).font(.caption)
                Button("閉じる") { capture.acknowledge() }.buttonStyle(.bordered)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func button(_ title: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(width: 220, height: 52)
                .background(color, in: Capsule())
                .foregroundStyle(color == .red ? .white : .black)
        }
    }
}
