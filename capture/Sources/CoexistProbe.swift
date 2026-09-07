import ARKit
import Foundation
import RoomPlan

/// RoomPlan と MDR 撮影を **1 つの ARSession で同時に走らせられるか**を実測する。
///
/// 背景: 別セッションで 2 回撮る方式は成立しているが、撮影時間が倍になり、
/// RoomPlan の部屋座標と MDR の ARKit world 座標が無関係になるため、
/// 間取り図を 3D モデルに重ねるには位置合わせが要る。
///
/// iOS 17 で `RoomCaptureSession(arSession:)` が入り、自前のセッションを渡せる
/// ようになった（`arSession` プロパティも public）。`RoomPlanCapture.swift` の
/// 「差し込めない」というコメントは iOS 16 時代の記述で、古い。
///
/// **測るのは時間ではなく採用フレーム数。** 焼き込みは 97% が UV 展開で CPU 律速、
/// RoomPlan の最終処理は ML なので資源が競合しにくい。危ないのは撮影中で、
/// RoomPlan が常時 ML を回すぶん我々の JPEG 圧縮・キーフレーム判定と competing する。
/// フレームが減れば埋まらないテクセルが増え、黒い斑点として見える
/// （実測で 2 ポイントの増加が目視で分かった）。A12Z / 6GB では現実的な懸念。
///
/// 失敗しても損はない。駄目なら現状の 2 回撮る方式に戻るだけ。
@available(iOS 17.0, *)
@MainActor
final class CoexistProbe: NSObject, ObservableObject {

    struct Sample: Codable {
        var roomPlanEnabled: Bool
        var seconds: Double
        var arFrames: Int
        var acceptedFrames: Int
        var arFPS: Double
        var acceptedFPS: Double
        var videoWidth: Int
        var videoHeight: Int
        var sceneDepthEnabled: Bool
        var meshClassificationEnabled: Bool
        var worldAlignment: String
        var thermalStart: String
        var thermalEnd: String
        var peakMemoryMB: Int
        var roomWalls: Int
        var roomObjects: Int
        /// sceneReconstruction の生の値。
        ///
        /// **これは列挙値ではなくビットマスク**（OptionSet）で、RoomPlan 経由では
        /// 27 のような公開 API に無い値が入る。設定値から挙動を読むのは諦めて、
        /// `meshAnchors` / `meshVertices` で実際に届いたかを見ること。
        ///
        /// 分類の有無は問題ではない。我々は ARMeshAnchor の頂点と面しか使わず、
        /// 分類はコード中のどこからも参照していない。
        var sceneReconstructionRaw: Int = -1
        /// 実際に届いた ARMeshAnchor の数と頂点数。設定値より確実な証拠になる。
        var meshAnchors: Int = 0
        var meshVertices: Int = 0
        /// RoomPlan の起動後に深度を再適用したか。
        var depthReapplied: Bool = false
        /// 深度付きフレームが何枚届いたか。設定値より確実な証拠。
        var framesWithDepth: Int = 0
        var error: String?
    }

    @Published private(set) var running = false
    @Published private(set) var status = "未実行"
    @Published private(set) var samples: [Sample] = []

    private var session: ARSession?
    private var roomSession: RoomCaptureSession?
    private var arFrameCount = 0
    private var acceptedCount = 0
    private var startedAt: CFAbsoluteTime = 0
    private var peakMemory: UInt64 = 0
    private var thermalStart: ProcessInfo.ThermalState = .nominal
    private var latestRoom: CapturedRoom?
    private var failure: String?
    private var meshAnchorIDs: Set<UUID> = []
    private var meshVertexCount = 0
    private var framesWithDepth = 0
    private var reapplied = false
    private var activeConfig: ARWorldTrackingConfiguration?

    /// キーフレーム判定は本番と同じものを使う。ここを簡略化すると、
    /// 「採用フレームが減るか」という問いに答えられなくなる。
    private var selector = KeyframeSelector()
    private let confidenceHigh = UInt8(ARConfidenceLevel.high.rawValue)

    private let duration: TimeInterval

    init(duration: TimeInterval = 30) {
        self.duration = duration
        super.init()
        // 既存の結果を読み込んでから追記する。読まずに書くと、アプリを開き直した
        // 時点で配列が空に戻り、前回の計測を上書きして消してしまう。
        if let url = Self.fileURL, let data = try? Data(contentsOf: url),
           let old = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = old
            status = Self.describe(old)
        }
    }

    private static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("coexist_probe.json")
    }

    // MARK: - 計測

    func run(withRoomPlan: Bool, reapplyDepth: Bool = false) {
        guard !running else { return }
        running = true
        failure = nil
        arFrameCount = 0
        acceptedCount = 0
        peakMemory = 0
        latestRoom = nil
        meshAnchorIDs.removeAll()
        meshVertexCount = 0
        framesWithDepth = 0
        reapplied = false
        selector.reset()
        thermalStart = ProcessInfo.processInfo.thermalState
        status = withRoomPlan ? "RoomPlan あり 計測中" : "RoomPlan なし 計測中"

        let session = ARSession()
        session.delegate = self
        self.session = session

        // 本番と同じ設定で走らせる。RoomPlan が上書きするかどうかも観測対象。
        let report = DeviceProbe.run()
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        if report.supportsSceneReconstruction {
            config.sceneReconstruction = .meshWithClassification
        }
        if report.supportsSceneDepth {
            config.frameSemantics.insert(.sceneDepth)
        }
        if let f = DeviceProbe.preferredFormat(from: report.videoFormats) {
            config.videoFormat = f
        }
        activeConfig = config
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        if withRoomPlan {
            // 自前のセッションを渡す。ここが今回の検証点。
            let rs = RoomCaptureSession(arSession: session)
            rs.delegate = self
            roomSession = rs
            // 音声・画面のコーチングは我々の UI と衝突するので切る。
            var rc = RoomCaptureSession.Configuration()
            rc.isCoachingEnabled = false
            rs.run(configuration: rc)

            if reapplyDepth {
                // **RoomPlan は共有セッションを自前の設定で上書きする。**
                // その設定に sceneDepth が含まれず、深度付きフレームが 1 枚も
                // 来なくなることがある（実測: 採用 0 枚）。しかも挙動が一貫せず、
                // 順序を変えると有効になったりする。競合状態がある。
                //
                // 上書きされた後に深度だけ戻す。resetTracking は付けない。
                // 付けると RoomPlan が積み上げた状態を壊す。
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, let s = self.session,
                          let base = s.configuration as? ARWorldTrackingConfiguration
                    else { return }
                    base.frameSemantics.insert(.sceneDepth)
                    self.activeConfig = base
                    s.run(base, options: [])
                    self.reapplied = true
                }
            }
        }

        startedAt = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.finish(roomPlanEnabled: withRoomPlan)
        }
    }

    private func finish(roomPlanEnabled: Bool) {
        let seconds = CFAbsoluteTimeGetCurrent() - startedAt
        // **実際に有効になった設定**を読む。要求した設定と一致するとは限らない。
        let active = session?.configuration as? ARWorldTrackingConfiguration
        let res = active?.videoFormat.imageResolution ?? .zero

        let sample = Sample(
            roomPlanEnabled: roomPlanEnabled,
            seconds: seconds,
            arFrames: arFrameCount,
            acceptedFrames: acceptedCount,
            arFPS: Double(arFrameCount) / max(seconds, 0.001),
            acceptedFPS: Double(acceptedCount) / max(seconds, 0.001),
            videoWidth: Int(res.width),
            videoHeight: Int(res.height),
            sceneDepthEnabled: active?.frameSemantics.contains(.sceneDepth) ?? false,
            meshClassificationEnabled: active?.sceneReconstruction == .meshWithClassification,
            worldAlignment: Self.name(active?.worldAlignment),
            thermalStart: Self.name(thermalStart),
            thermalEnd: Self.name(ProcessInfo.processInfo.thermalState),
            peakMemoryMB: Int(peakMemory / 1_048_576),
            roomWalls: latestRoom?.walls.count ?? 0,
            roomObjects: latestRoom?.objects.count ?? 0,
            sceneReconstructionRaw: active.map { Int($0.sceneReconstruction.rawValue) } ?? -1,
            meshAnchors: meshAnchorIDs.count,
            meshVertices: meshVertexCount,
            depthReapplied: reapplied,
            framesWithDepth: framesWithDepth,
            error: failure
        )

        roomSession?.stop(pauseARSession: true)
        roomSession = nil
        session?.pause()
        session = nil

        samples.append(sample)
        write()
        running = false
        status = Self.describe(samples)
    }

    private func write() {
        guard let url = Self.fileURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(samples) {
            try? data.write(to: url)
        }
    }

    private static func describe(_ samples: [Sample]) -> String {
        guard let off = samples.last(where: { !$0.roomPlanEnabled }) else {
            return "RoomPlan なしを先に計測してください"
        }
        var lines = [String(format: "なし: %.1f fps 採用 / %d 枚 / %dx%d / 熱 %@",
                            off.acceptedFPS, off.acceptedFrames,
                            off.videoWidth, off.videoHeight, off.thermalEnd)]
        if let on = samples.last(where: { $0.roomPlanEnabled }) {
            lines.append(String(format: "あり: %.1f fps 採用 / %d 枚 / %dx%d / 熱 %@",
                                on.acceptedFPS, on.acceptedFrames,
                                on.videoWidth, on.videoHeight, on.thermalEnd))
            let ratio = on.acceptedFPS / max(off.acceptedFPS, 0.001)
            lines.append(String(format: "採用フレーム %.0f%%  壁 %d 枚", ratio * 100, on.roomWalls))
            let names = ["none", "mesh", "meshWithClassification"]
            let raw = on.sceneReconstructionRaw
            let label = (0..<names.count).contains(raw) ? names[raw] : "?\(raw)"
            lines.append(String(format: "メッシュ: %@ / アンカー %d / 頂点 %d",
                                label, on.meshAnchors, on.meshVertices))
            lines.append(String(format: "深度付きフレーム %d / %d 枚%@",
                                on.framesWithDepth, on.arFrames,
                                on.depthReapplied ? "（再適用あり）" : ""))
            if on.framesWithDepth == 0 {
                lines.append("** 深度が 1 枚も来ていません。MDR が成立しません **")
            }
            if on.meshAnchors == 0 {
                lines.append("** メッシュが来ていません。3D モデルが作れません **")
            }
            if on.videoWidth != off.videoWidth || on.videoHeight != off.videoHeight {
                lines.append("** 映像解像度が変わりました。MDR の品質に直接響きます **")
            }
            if !on.sceneDepthEnabled {
                lines.append("** 深度が無効になりました **")
            }
            if let e = on.error { lines.append("エラー: \(e)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func name(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func name(_ a: ARConfiguration.WorldAlignment?) -> String {
        switch a {
        case .gravity: return "gravity"
        case .gravityAndHeading: return "gravityAndHeading"
        case .camera: return "camera"
        default: return "unknown"
        }
    }

    private static func residentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }
}

@available(iOS 17.0, *)
extension CoexistProbe: ARSessionDelegate {
    /// メッシュが実際に届いているかを数える。設定値より確実。
    private func note(_ anchors: [ARAnchor]) {
        for a in anchors.compactMap({ $0 as? ARMeshAnchor }) {
            if meshAnchorIDs.insert(a.identifier).inserted {
                meshVertexCount += a.geometry.vertices.count
            }
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { note(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { note(anchors) }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        arFrameCount += 1
        peakMemory = max(peakMemory, Self.residentMemory())
        if frame.sceneDepth != nil { framesWithDepth += 1 }
        // 本番と同じ判定を通す。採用されるかどうかが知りたい値なので、
        // ここで手を抜くと計測の意味がなくなる。
        guard let depth = frame.sceneDepth else { return }
        let metrics = KeyframeSelector.Metrics(
            sharpness: FrameMetrics.sharpness(of: frame.capturedImage),
            confidenceHighRatio: depth.confidenceMap.map {
                FrameMetrics.confidenceHighRatio(of: $0, highValue: confidenceHigh)
            } ?? 1.0
        )
        if selector.evaluate(frame: frame, metrics: metrics,
                             confidenceHighValue: confidenceHigh).isAccepted {
            acceptedCount += 1
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        failure = error.localizedDescription
    }
}

@available(iOS 17.0, *)
extension CoexistProbe: RoomCaptureSessionDelegate {
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        latestRoom = room
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {}

    func captureSession(_ session: RoomCaptureSession,
                        didEndWith data: CapturedRoomData, error: Error?) {
        if let error { failure = error.localizedDescription }
    }
}
