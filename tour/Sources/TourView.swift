import MetalKit
import SwiftUI
import simd

/// MTKView を SwiftUI に載せ、ドラッグで見回し・クリックで前進を扱う。
struct MetalTourView: NSViewRepresentable {
    let renderer: TourRenderer
    let camera: TourCamera
    var onToggle: (() -> Void)?

    func makeNSView(context: Context) -> MTKView {
        let view = TrackingMTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
        view.delegate = renderer
        view.preferredFramesPerSecond = 60
        view.camera = camera
        view.onToggle = onToggle
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}

/// マウス入力を受けるための MTKView。
///
/// SwiftUI の DragGesture でも見回しは作れるが、MTKView に直接載せた方が
/// 遅延が少なく、スクロールやキーも同じ場所で扱える。
final class TrackingMTKView: MTKView {
    weak var camera: TourCamera?
    /// Tab で呼ばれる。盲検の A/B 切り替えに使う。
    var onToggle: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        // 感度は「画面幅のドラッグで約 180 度」を目安にした
        let s: Float = 0.005
        Task { @MainActor in
            camera?.look(deltaYaw: Float(event.deltaX) * s,
                         deltaPitch: Float(-event.deltaY) * s)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // ドラッグではない単純なクリックを前進とみなす
        guard event.clickCount == 1 else { return }
        Task { @MainActor in camera?.advance() }
    }

    override func keyDown(with event: NSEvent) {
        Task { @MainActor in
            switch event.keyCode {
            case 48: onToggle?()                     // Tab: モデル切り替え
            case 126, 13: camera?.advance()          // ↑ / W
            case 123, 0:  camera?.look(deltaYaw: -0.12, deltaPitch: 0)  // ← / A
            case 124, 2:  camera?.look(deltaYaw:  0.12, deltaPitch: 0)  // → / D
            default: break
            }
        }
    }
}

struct TourView: View {
    let tour: Tour
    /// 複数渡すと Tab で切り替えられる。どれがどれかは表示しない（盲検）。
    let splatURLs: [URL]

    @StateObject private var camera: TourCamera
    @State private var renderer: TourRenderer?
    @State private var status = "準備中"
    @State private var shown = 0

    init(tour: Tour, splatURLs: [URL]) {
        self.tour = tour
        self.splatURLs = splatURLs
        _camera = StateObject(wrappedValue: TourCamera(tour: tour))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let renderer {
                MetalTourView(renderer: renderer, camera: camera, onToggle: {
                    renderer.toggle()
                    shown = renderer.currentIndex
                }).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(status).font(.system(.caption, design: .monospaced))
                Text("station \(camera.currentStation + 1) / \(tour.stations.count)")
                    .font(.system(.caption, design: .monospaced))
                if splatURLs.count > 1 {
                    // 記号だけ出す。ファイル名を出すと盲検にならない。
                    Text("表示中: \(["甲", "乙", "丙", "丁"][min(shown, 3)])")
                        .font(.system(.title3, design: .monospaced)).bold()
                    Text("ドラッグ: 見回す   クリック / ↑: 進む   Tab: 切り替え")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("ドラッグ: 見回す   クリック / ↑: 進む")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()

            // station の一覧。任意の場所へ直接飛べる。
            VStack {
                Spacer()
                HStack(spacing: 6) {
                    ForEach(tour.stations) { s in
                        Button("\(s.index + 1)") { camera.move(to: s.index) }
                            .buttonStyle(.bordered)
                            .tint(s.index == camera.currentStation ? .accentColor : .gray)
                    }
                }
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding()
            }
        }
        .task { await setup() }
    }

    private func setup() async {
        guard let device = MTLCreateSystemDefaultDevice() else {
            status = "Metal が使えません"; return
        }
        do {
            let r = try TourRenderer(device: device, camera: camera)
            r.onStatus = { s in status = s }
            renderer = r
            status = "読み込み開始"
            // 読み込みは背景で走らせる。ここで await すると
            // ウィンドウが出るまでの時間が読み込み時間になってしまう。
            // 全モデルを読み込んでから切り替える。切り替えのたびに読み直すと
            // 待ち時間そのものが判断を左右する。
            try await Task.detached(priority: .userInitiated) {
                for (i, u) in splatURLs.enumerated() {
                    r.onStatus?("読み込み \(i + 1)/\(splatURLs.count)")
                    try await r.load(splatURL: u)
                }
            }.value
            status = splatURLs.count > 1 ? "\(splatURLs.count) 件 読み込み完了" : status
        } catch {
            status = "エラー: \(error.localizedDescription)"
        }
    }
}
