import ARKit
import RoomPlan
import UIKit
import Combine
import Foundation
import simd

/// ARSession を回してキーフレームを MDR バンドルに落とす。
///
/// 設定の要点（docs/pipeline.md §2）:
/// - `worldAlignment = .gravity` … Y 軸が重力に一致し床・壁が軸整合になる。
///   **`.gravityAndHeading` は使わない。** 間取り図に真北を入れるために一度
///   採用したが、実測で 2 回とも磁気コンパスの精度が 28.8° / 27.3° と
///   使用に耐えず（上限は 20°）、方位は得られなかった。得るものが無い一方で、
///   同じ期間に焼き込みが 30 倍以上遅くなり最後にアプリが落ちたため、
///   撮影経路を速かった時点の挙動に戻した。原因の切り分けは
///   `docs/timing-and-quality.md`。
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
    /// RoomPlan が検出した壁・物体の数。撮影中の手応えとして出す。
    @Published private(set) var roomWalls = 0
    @Published private(set) var roomObjects = 0

    /// `RoomBuilder` が返った間取り。端末で平面図を出すために保持する。
    ///
    /// `CapturedRoom` は iOS 17 以降の型なので `AnyObject` で持つ。
    /// **平面図はメッシュも画像も要らない**（`FloorPlan` 参照）ので、
    /// 焼き込みを待たずにこれが入った時点で図を出せる。
    @Published private(set) var roomReady = false
    private var finalRoom: AnyObject?

    @available(iOS 17.0, *)
    var capturedRoom: CapturedRoom? { finalRoom as? CapturedRoom }

    /// 平面図に描く北。**`.gravity` では取れないので常に nil。**
    ///
    /// 過去のスキャンについては `ScanLibrary` が manifest から判定する
    /// （`world_alignment` が `gravityAndHeading` かつ `heading.usable` のときだけ）。
    var planNorth: SIMD2<Double>? { nil }

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

    /// manifest に残す world 座標の揃え方。
    private let appliedAlignment = "gravity"

    // MARK: 離脱の検出
    //
    // **焼き込み中にアプリを離れると計算が止まる。** iOS はバックグラウンドの
    // プロセスを約 30 秒で停止し、やがて終了させる。壁時計は進むので、記録上は
    // 「異常に遅い焼き込み」に見える。実測で 3 回、bake.json が出ないまま
    // プロセスが入れ替わっていた。
    //
    // 停止された時間を数えて bake.json に残し、UI でも離れないよう伝える。

    /// 焼き込み中である。UI が警告を出すために使う。
    @Published private(set) var isBaking = false
    private var backgroundEvents = 0
    private var backgroundSeconds: Double = 0
    private var backgroundEnteredAt: TimeInterval?
    private var observers: [NSObjectProtocol] = []

    private func watchBackgroundTransitions() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: nil) { [weak self] _ in
                self?.queue.async {
                    self?.backgroundEvents += 1
                    self?.backgroundEnteredAt = CFAbsoluteTimeGetCurrent()
                }
            })
        observers.append(nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: nil) { [weak self] _ in
                self?.queue.async {
                    guard let self, let t = self.backgroundEnteredAt else { return }
                    self.backgroundSeconds += CFAbsoluteTimeGetCurrent() - t
                    self.backgroundEnteredAt = nil
                }
            })
    }

    /// 焼き込み用のフレーム保持と GPU 実装。撮影と並行して溜める。
    private let encoder = ImageEncoder()
    private var frameStore: FrameStore?
    private var baker: OnDeviceBaker?

    /// MDR と同じ ARSession の上で回す RoomPlan。詳細は `RoomScan`。
    ///
    /// **撮影開始前から回す。** RoomPlan は起動時に共有セッションから
    /// `.sceneDepth` を落とすため、戻すまでの約 1.5 秒は深度が来ない。
    /// 録画ボタンを押す前に済ませておけば、記録されるフレームは全て深度付きになる。
    private var roomScan: AnyObject?

    @available(iOS 17.0, *)
    private var typedRoomScan: RoomScan? { roomScan as? RoomScan }

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

        watchBackgroundTransitions()
        let config = makeConfiguration(report)
        DispatchQueue.main.async { self.probe = report }

        session.delegate = self
        session.delegateQueue = queue
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        // 同一セッションで RoomPlan も回す。座標系が一致するので、
        // 間取り図と 3D モデルを重ねるための位置合わせが要らなくなる。
        if #available(iOS 17.0, *) {
            let scan = RoomScan()
            roomScan = scan
            scan.start(on: session)
            // 撮影中の手応え表示のため、検出数を定期的に拾う。
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                guard let self, let scan = self.typedRoomScan, scan.isRunning else {
                    t.invalidate(); return
                }
                self.roomWalls = scan.wallCount
                self.roomObjects = scan.objectCount
            }
        }
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
                if let device = MTLCreateSystemDefaultDevice() {
                    let store = FrameStore(device: device)
                    store.debugDirectory = self.writer?.bundleURL
                    self.frameStore = store
                    Task { @MainActor in self.baker = try? OnDeviceBaker() }
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
                try writer.finish(probe: report, format: format,
                                  gravity: SIMD3<Float>(0, -1, 0),
                                  worldAlignment: self.appliedAlignment)
                let url = writer.bundleURL

                // RoomPlan は**止めるだけ**。`RoomBuilder` は回さない。
                //
                // 以前は焼き込みと並行させていた（「ML なので競合しにくい」
                // という想定）。実測でそれは誤りだった。room-428768ea は
                // 壁時計 202.5 秒に対しプロセスの CPU 時間 1077 秒で、
                // 残メモリ 3.3GB・温度 nominal・離脱 0 秒。xatlas の
                // スケジューラがタスクごとに全ワーカを起こし、待機は
                // `yield()` のスピンなので、コアを取り合うと空回りが爆発する。
                //
                // 端末側は最速の 3D 生成と最低限の RoomPlan 撮影だけを担い、
                // 精細化と間取り図はサーバ側（M1 Max）に寄せる。
                if #available(iOS 17.0, *), let scan = self.typedRoomScan {
                    Task { @MainActor in
                        let room = await scan.finish()
                        scan.writeRawData(to: url)
                        if let room {
                            scan.write(room, to: url)
                            self.roomWalls = room.walls.count
                            self.roomObjects = room.objects.count
                            self.finalRoom = room as AnyObject
                            self.roomReady = true
                        }
                    }
                }

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
                // 同期的に取り込む。ARKit はピクセルバッファをプールから再利用するので、
                // 非同期に逃がすと別フレームの内容を読んでしまう。
                frameStore?.append(frame: frame, sharpness: Float(metrics.sharpness), encoder: encoder)
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

        let frames = store.frames
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

        publish { $0.bakeProgress = 0; $0.isBaking = true }
        backgroundEvents = 0
        backgroundSeconds = 0
        backgroundEnteredAt = nil
        // バックグラウンドでも少しだけ猶予をもらう。恒久的な解決にはならない
        // （iOS が与えるのは数十秒）が、切り替えた直後に殺されるのは防げる。
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "bake")
        defer {
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            publish { $0.isBaking = false }
        }
        do {
            let result = try MainActor.assumeIsolatedSafely {
                try baker.bake(meshVertices: vertices, meshIndices: indices, frames: frames) { n, total in
                    self.publish { $0.bakeProgress = Double(n) / Double(total) }
                }
            }
            // GLB は Blender / Three.js など外部ツール向け。
            let glb = bundleURL.appendingPathComponent("mesh.glb")
            try GLBWriter.write(vertices: result.vertices, uvs: result.uvs, indices: result.indices,
                                textureRGBA: result.texture, atlasSize: result.atlasSize, to: glb)

            // USDZ は iPad 上での確認用。iOS の Quick Look は GLB を開けない。
            let usdz = bundleURL.appendingPathComponent("mesh.usdz")
            do {
                try USDZWriter.write(vertices: result.vertices, uvs: result.uvs, indices: result.indices,
                                     textureRGBA: result.texture, atlasSize: result.atlasSize, to: usdz)
            } catch {
                // USDZ が失敗しても GLB は残っているので撮影成果は失われない
                print("USDZ 書き出しに失敗: \(error.localizedDescription)")
            }
            // 内訳をバンドルに残す。画面を目視して口頭で伝える運用は、
            // この案件で繰り返し測定ミスの原因になっている。機械で読める形に置く。
            let stats: [String: Any] = [
                "elapsed_sec": result.elapsed,
                "stages_sec": [
                    "unwrap": result.timings.unwrap,
                    "rasterize": result.timings.rasterize,
                    "project": result.timings.project,
                    "resolve": result.timings.resolve,
                ],
                // **壁時計と CPU 時間の両方を残す。**
                // バックグラウンドに回るとプロセスは停止され、計算は進まないが
                // 壁時計は進む。CPU が壁時計を大きく下回っていれば、その差は
                // アプリを離れていた時間。xatlas は複数スレッドを使うので、
                // 離れていなければ CPU > 壁時計 になるのが正常。
                "cpu_sec": result.timings.cpu,
                "background_events": self.backgroundEvents,
                "background_sec": self.backgroundSeconds,
                "triangles": result.indices.count / 3,
                "vertices": result.vertices.count,
                "atlas_size": result.atlasSize,
                "frames": frames.count,
                "unfilled_ratio": Double(result.unfilledRatio),
                "device": UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
                // **性能を語る前に構成を記録する。** Debug で入れると xatlas が
                // 最適化なしになり、実測 6.5 倍遅くなる（BuildInfo 参照）。
                "build_configuration": BuildInfo.configuration,
                "xatlas_flags": BuildInfo.xatlasFlags,
                "thermal_state": BuildInfo.thermalStateName,
                // **低電力モードは thermalState に出ない。** クロックを大きく
                // 下げるので、熱を否定しても絞られている可能性が残る。
                // 実測で残量 5% のときに焼き込みが 200 秒級だった。
                "low_power_mode": BuildInfo.isLowPowerMode,
                "battery_level": BuildInfo.batteryLevel ?? -1,
                "battery_state": BuildInfo.batteryStateName,
                // 面数はスキャンごとに変わるので、秒数だけでは速いか遅いか
                // 分からない。面で割った値が構成に依存しない検出指標になる。
                "unwrap_us_per_triangle": BuildInfo.Metrics.unwrapMicrosecondsPerTriangle(
                    unwrapSec: result.timings.unwrap,
                    triangles: result.indices.count / 3) ?? 0,
                // 展開の内訳。**計算量かメモリ逼迫かを切り分けるため。**
                // Mac では ComputeCharts が支配的（148,897 面 7.19 秒 /
                // 192,403 面 13.66 秒）なのに、端末は 13.91 -> 178.41 秒
                // （12.8 倍）になった。段階と残メモリが分かれば決まる。
                "unwrap_detail": [
                    "add_mesh_sec": result.unwrapDetail.addMesh,
                    "compute_charts_sec": result.unwrapDetail.computeCharts,
                    "pack_charts_sec": result.unwrapDetail.packCharts,
                    "build_output_sec": result.unwrapDetail.buildOutput,
                    "charts": result.unwrapDetail.charts,
                    "hardware_concurrency": result.unwrapDetail.hardwareConcurrency,
                    "available_memory_before_mb":
                        Double(result.unwrapDetail.availableMemoryBefore) / 1e6,
                    "available_memory_after_mb":
                        Double(result.unwrapDetail.availableMemoryAfter) / 1e6,
                    "available_memory_min_mb":
                        Double(result.unwrapDetail.availableMemoryMin) / 1e6,
                ],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: stats,
                                                      options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: bundleURL.appendingPathComponent("bake.json"))
            }

            let summary = String(format: "%.0f 秒 / %d 三角形 / 未着色 %.1f%%\n%@ / %d フレーム",
                                 result.elapsed, result.indices.count / 3,
                                 result.unfilledRatio * 100,
                                 result.timings.summary, frames.count)
            if let x = BuildInfo.Metrics.slowdown(unwrapSec: result.timings.unwrap,
                                                 triangles: result.indices.count / 3),
               x > BuildInfo.Metrics.slowdownAlarm {
                print("警告: UV 展開が基準の \(String(format: "%.1f", x)) 倍遅い。"
                      + "構成 \(BuildInfo.configuration) / 温度 \(BuildInfo.thermalStateName)")
            }
            print("焼き込み内訳: \(result.timings.summary) / 合計 " +
                  String(format: "%.1f", result.elapsed) + "s")
            publish { $0.bakeProgress = nil; $0.bakeSummary = summary }
        } catch {
            publish { $0.bakeProgress = nil; $0.bakeSummary = "焼き込み失敗: \(error.localizedDescription)" }
        }
        store.reset()
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
