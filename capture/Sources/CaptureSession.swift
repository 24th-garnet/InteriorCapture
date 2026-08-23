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
    /// オンデバイス焼き込みの進捗（0..1）。nil なら実行していない。
    @Published private(set) var bakeProgress: Double?
    @Published private(set) var bakeSummary: String?

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

    /// 焼き込み用のフレーム保持と GPU 実装。撮影と並行して溜める。
    private let encoder = ImageEncoder()
    private var frameStore: FrameStore?
    private var baker: OnDeviceBaker?

    // MARK: - セットアップ

    func attach(to session: ARSession) {
        self.session = session
        let report = DeviceProbe.run()
        deviceReport = report
        print("=== DeviceProbe ===\n\(report.summary)\n===================")

        // Documents に残す。実機の素性は「想定ではなく実測」で押さえたいので、
        // 起動のたびに上書きして最新を保持する。ファイル App から取り出せるほか、
        // devicectl でも吸い出せる。
        if let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first {
            try? report.summary.write(
                to: documents.appendingPathComponent("deviceprobe.txt"),
                atomically: true, encoding: .utf8
            )
        }

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
                Task { @MainActor in
                    if let device = MTLCreateSystemDefaultDevice() {
                        let store = FrameStore(device: device)
                        self.baker = try? OnDeviceBaker()
                        self.queue.async { self.frameStore = store }
                    }
                }
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

                // Tier 1: テクスチャ付きメッシュを iPad 上で生成する。
                // 3DGS は Mac 側に残す（A12Z では非現実的で、Scaniverse 自身も
                // この世代では splat を提供していない）。
                self.bakeOnDevice(anchors: anchors, bundleURL: url)

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
                // 焼き込み用にも保持する。ディスクの JPEG を読み直すと
                // 605 枚のデコードだけで数十秒かかるため、GPU 上に持っておく。
                if let store = frameStore {
                    let f = frame
                    let sharp = Float(metrics.sharpness)
                    Task { @MainActor in store.append(frame: f, sharpness: sharp, encoder: self.encoder) }
                }
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


// MARK: - オンデバイス焼き込み

extension CaptureSession {

    /// ARKit メッシュと保持したキーフレームから GLB を作る。
    ///
    /// 失敗しても撮影データ（MDR バンドル）は既に書き終えているので、
    /// ここでの例外は成果物を失わせない。Mac 側で焼き直せる。
    fileprivate func bakeOnDevice(anchors: [ARMeshAnchor], bundleURL: URL) {
        guard let baker, let store = frameStore else { return }

        let frames = MainActor.assumeIsolatedSafely { store.frames }
        guard !frames.isEmpty else { return }

        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for anchor in anchors {
            let base = UInt32(vertices.count)
            let g = anchor.geometry
            let t = anchor.transform
            for i in 0..<g.vertices.count {
                let off = g.vertices.offset + g.vertices.stride * i
                let local = g.vertices.buffer.contents().advanced(by: off)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let w = t * SIMD4<Float>(local.x, local.y, local.z, 1)
                vertices.append(SIMD3(w.x, w.y, w.z))
            }
            let fb = g.faces
            let raw = fb.buffer.contents().assumingMemoryBound(to: Int32.self)
            for f in 0..<fb.count {
                let o = f * fb.indexCountPerPrimitive
                indices.append(base + UInt32(raw[o]))
                indices.append(base + UInt32(raw[o + 1]))
                indices.append(base + UInt32(raw[o + 2]))
            }
        }
        guard vertices.count > 2, indices.count > 2 else { return }

        publish { $0.bakeProgress = 0 }
        do {
            let result = try MainActor.assumeIsolatedSafely {
                try baker.bake(meshVertices: vertices, meshIndices: indices, frames: frames) { n, total in
                    self.publish { $0.bakeProgress = Double(n) / Double(total) }
                }
            }
            let glb = bundleURL.appendingPathComponent("mesh.glb")
            try GLBWriter.write(vertices: result.vertices, uvs: result.uvs, indices: result.indices,
                                textureRGBA: result.texture, atlasSize: result.atlasSize, to: glb)
            let summary = String(format: "%.0f 秒 / %d 三角形 / 未着色 %.1f%%",
                                 result.elapsed, result.indices.count / 3,
                                 result.unfilledRatio * 100)
            publish { $0.bakeProgress = nil; $0.bakeSummary = summary }
        } catch {
            publish { $0.bakeProgress = nil; $0.bakeSummary = "焼き込み失敗: \(error.localizedDescription)" }
        }
        MainActor.assumeIsolatedSafely { store.reset() }
    }
}

/// `queue` から @MainActor の状態へ触れるための同期ヘルパ。
///
/// FrameStore と OnDeviceBaker は Metal 資源を持つため @MainActor に置いているが、
/// 焼き込み自体は撮影完了後の一括処理で、UI を止めても実害がない。
private func MainActor_assumeIsolatedSafely<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated { try body() }
    }
    return try DispatchQueue.main.sync { try MainActor.assumeIsolated { try body() } }
}

extension MainActor {
    static func assumeIsolatedSafely<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        try MainActor_assumeIsolatedSafely(body)
    }
}
