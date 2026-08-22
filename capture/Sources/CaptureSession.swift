import ARKit
import Combine
import Foundation
import simd

/// ARSession を回してキーフレームを MDR バンドルに落とす。
///
/// 設定の要点（docs/pipeline.md §2）:
/// - `worldAlignment = .gravity` … Y 軸が重力に一致し床・壁が軸整合になる。
///   `.gravityAndHeading` は磁気コンパス依存で室内では不安定なので使わない。
/// - `frameSemantics = [.sceneDepth]` … 生の深度のみ。smoothed は併用しない（A12Z の負荷）。
/// - 1920x1440 @30fps … A12Z は ARKit 4K 非対応。60fps は熱予算を食うだけ。
///
/// スレッド設計: 録画状態と writer は `queue`（専用シリアルキュー）だけが触る。
/// UI に見せる値は `@Published` としてメインスレッドで更新する。
/// ARSessionDelegate も `queue` で呼ばれるのでロックは要らない。
final class CaptureSession: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case finishing
        case finished(URL)
        case failed(String)
    }

    // MARK: UI 向け（メインスレッドでのみ更新）

    @Published private(set) var state: State = .idle
    @Published private(set) var acceptedCount = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastRejection: String = ""
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published private(set) var probe: DeviceProbe.Report?

    /// A12Z の発熱で長時間の撮影は品質が落ちる。Scaniverse の docs 上限 5 分より保守的に切る。
    /// 公式サポートも「1〜3 分がベスト、それ以上は品質が落ちる」としている。
    static let maxDuration: TimeInterval = 180

    // MARK: queue 専用（他スレッドから触らない）

    private let queue = DispatchQueue(label: "madoriba.capture", qos: .userInitiated)
    private var writer: MDRWriter?
    private var selector = KeyframeSelector()
    private var isRecording = false
    private var startTime: TimeInterval?

    /// SDK の定義を信頼する。実装によって 1..3 として観測されるという報告があるが、
    /// enum の rawValue が正であり、DeviceProbe のログで実データと突き合わせる。
    private let confidenceHigh = UInt8(ARConfidenceLevel.high.rawValue)

    private var videoFormat: ARConfiguration.VideoFormat?
    private var deviceReport: DeviceProbe.Report?
    private weak var session: ARSession?

    // MARK: - セットアップ

    func attach(to session: ARSession) {
        self.session = session
        let report = DeviceProbe.run()
        deviceReport = report
        print("=== DeviceProbe ===\n\(report.summary)\n===================")

        let config = makeConfiguration(report)
        DispatchQueue.main.async { self.probe = report }

        session.delegate = self
        session.delegateQueue = queue
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func makeConfiguration(_ report: DeviceProbe.Report) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.environmentTexturing = .none
        config.planeDetection = []

        if report.supportsSceneReconstruction {
            config.sceneReconstruction = .meshWithClassification
        }
        if report.supportsSceneDepth {
            config.frameSemantics.insert(.sceneDepth)
        }
        if let format = DeviceProbe.preferredFormat(from: report.videoFormats) {
            config.videoFormat = format
            videoFormat = format
        }
        return config
    }

    // MARK: - 録画制御

    func startRecording() {
        queue.async { [weak self] in
            guard let self, !self.isRecording else { return }
            do {
                let documents = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                )[0]
                let id = String(UUID().uuidString.prefix(8)).lowercased()
                self.writer = try MDRWriter(root: documents, sessionID: id)
                self.selector.reset()
                self.startTime = nil
                self.isRecording = true
                self.publish { $0.state = .recording; $0.acceptedCount = 0; $0.elapsed = 0 }
            } catch {
                self.publish { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    func stopRecording() {
        // メッシュはメインスレッド側の currentFrame から取り、あとは queue で処理する
        let anchors = (session?.currentFrame?.anchors ?? []).compactMap { $0 as? ARMeshAnchor }
        queue.async { [weak self] in
            guard let self, self.isRecording, let writer = self.writer else { return }
            self.isRecording = false
            self.publish { $0.state = .finishing }

            do {
                guard let report = self.deviceReport, let format = self.videoFormat else {
                    throw MDRWriter.WriterError.encodingFailed
                }
                // メッシュは Tier 1（間取り・寸法）用。失敗しても撮影データ本体は守る。
                try? writer.writeMesh(anchors: anchors)
                try writer.finish(probe: report, format: format, gravity: SIMD3<Float>(0, -1, 0))
                let url = writer.bundleURL
                self.publish { $0.state = .finished(url) }
            } catch {
                self.publish { $0.state = .failed(error.localizedDescription) }
            }
            self.writer = nil
        }
    }

    func acknowledge() {
        queue.async { [weak self] in
            self?.publish { $0.state = .idle }
        }
    }

    private func publish(_ mutate: @escaping (CaptureSession) -> Void) {
        DispatchQueue.main.async { mutate(self) }
    }
}

// MARK: - ARSessionDelegate

extension CaptureSession: ARSessionDelegate {

    /// - Note: `queue` で呼ばれる。JPEG エンコードもここで同期実行している。
    ///   キーフレームは実効 3〜6fps なので 30fps の入力に対して余裕があり、
    ///   詰まって落ちるのはどのみち捨てるフレームなので実害がない。
    ///   A12Z で追いつかないと分かったら、バッファをコピーして別キューに逃がす。
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording, let writer, let depth = frame.sceneDepth else { return }

        let metrics = KeyframeSelector.Metrics(
            sharpness: FrameMetrics.sharpness(of: frame.capturedImage),
            confidenceHighRatio: depth.confidenceMap.map {
                FrameMetrics.confidenceHighRatio(of: $0, highValue: confidenceHigh)
            } ?? 1.0
        )

        switch selector.evaluate(frame: frame, metrics: metrics, confidenceHighValue: confidenceHigh) {
        case .reject(let reason):
            publish { $0.lastRejection = reason }

        case .accept:
            do {
                try writer.write(frame: frame, metrics: metrics)
            } catch {
                publish { $0.state = .failed(error.localizedDescription) }
                isRecording = false
                return
            }

            if startTime == nil { startTime = frame.timestamp }
            let count = writer.frameCount
            let seconds = frame.timestamp - (startTime ?? frame.timestamp)
            let thermalState = ProcessInfo.processInfo.thermalState

            publish {
                $0.acceptedCount = count
                $0.elapsed = seconds
                $0.lastRejection = ""
                $0.thermal = thermalState
            }

            if seconds >= Self.maxDuration {
                stopRecording()
            }
        }
    }
}
