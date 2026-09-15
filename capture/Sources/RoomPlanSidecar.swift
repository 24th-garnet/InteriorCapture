import ARKit
import Foundation
import RoomPlan

/// 撮影に RoomPlan を**同居**させ、`room.json` をバンドルに並べる。
///
/// 3D 生成の側は一切変えない。増えるのは書き出すファイルと、停止後に
/// `RoomBuilder` が回る時間だけ。
///
/// **なぜ同居させるか。** メッシュの幾何だけでは家具を個体として取り出せない。
/// ARKit の面分類（`mesh_class.bin`）はクラスしか返さず、語彙も 8 種類で
/// ベッドも収納もソファも無い。RoomPlan の向き付き境界箱が唯一の個体情報。
///
/// **なぜ別セッションにしないか。** iOS 17 の `RoomCaptureSession(arSession:)`
/// に自前のセッションを渡せる。こうすると RoomPlan の座標が ARKit world と
/// 同一になり、位置合わせが要らない。2 回撮る方式は撮影時間が倍になる上、
/// 部屋座標と world 座標が無関係になる。
///
/// 実測で踏んだ罠が 2 つある（`coexist_probe.json`）:
///
/// - **RoomPlan は共有セッションの設定を自前で上書きする。** その設定に
///   `sceneDepth` が含まれず、**深度付きフレームが 1 枚も来なくなる**ことが
///   あった（採用 0 枚）。しかも順序で挙動が変わる競合がある。起動の
///   2 秒後に深度だけ入れ直す。`resetTracking` は付けない（RoomPlan が
///   積み上げた状態を壊す）
/// - `sceneReconstruction` の値は **OptionSet** で、RoomPlan 経由では 27 の
///   ような公開 API に無い値が入る。設定値から挙動を読まず、実際に届いた
///   ものを数えること
@available(iOS 17.0, *)
@MainActor
final class RoomPlanSidecar: NSObject {

    /// 深度を入れ直すまでの待ち。実測で 2 秒あれば RoomPlan の上書きは済んでいる。
    static let depthReapplyDelay: TimeInterval = 2.0
    /// `RoomBuilder` の待ち上限。**返ってこなくても撮影成果は守る。**
    static let buildTimeout: TimeInterval = 60

    private var session: RoomCaptureSession?
    private weak var arSession: ARSession?
    private var continuation: CheckedContinuation<CapturedRoomData?, Never>?
    private var startedAt: TimeInterval = 0
    private var depthReapplied = false
    private var liveWalls = 0
    private var liveObjects = 0
    private var failure: String?

    var isRunning: Bool { session != nil }

    // MARK: 開始

    func start(on arSession: ARSession) {
        guard session == nil else { return }
        self.arSession = arSession
        startedAt = CFAbsoluteTimeGetCurrent()
        depthReapplied = false
        liveWalls = 0
        liveObjects = 0
        failure = nil

        let rs = RoomCaptureSession(arSession: arSession)
        rs.delegate = self
        var config = RoomCaptureSession.Configuration()
        // 音声と画面のコーチングは我々の上下分割 UI と衝突する。
        config.isCoachingEnabled = false
        rs.run(configuration: config)
        session = rs

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.depthReapplyDelay) { [weak self] in
            self?.reapplyDepth()
        }
    }

    /// RoomPlan に上書きされた設定へ深度だけ戻す。
    private func reapplyDepth() {
        guard session != nil, let ar = arSession,
              let base = ar.configuration as? ARWorldTrackingConfiguration else { return }
        base.frameSemantics.insert(.sceneDepth)
        ar.run(base, options: [])       // resetTracking は付けない
        depthReapplied = true
    }

    // MARK: 停止と書き出し

    /// 停止して `room.json` を書く。統計を返す（`bake.json` に載せる用）。
    ///
    /// **焼き込みの後に呼ぶこと。** `RoomBuilder` は数秒かかるので、
    /// 焼き込みと同時に走らせると焼き込み秒数の比較が濁る。
    func finish(bundleURL: URL) async -> [String: Any] {
        guard let rs = session else { return [:] }
        let capturedSec = CFAbsoluteTimeGetCurrent() - startedAt
        session = nil

        // **AR セッションは止めない。** プレビューと次の撮影がこのセッションを
        // 使い続ける。
        rs.stop(pauseARSession: false)

        let buildStart = CFAbsoluteTimeGetCurrent()
        let data = await withCheckedContinuation { (c: CheckedContinuation<CapturedRoomData?, Never>) in
            continuation = c
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.buildTimeout * 1e9))
                await self?.resume(with: nil, reason: "RoomBuilder が返らない")
            }
        }

        var stats: [String: Any] = [
            "enabled": true,
            "captured_sec": capturedSec,
            "depth_reapplied": depthReapplied,
            "live_walls": liveWalls,
            "live_objects": liveObjects,
        ]
        guard let data else {
            stats["error"] = failure ?? "CapturedRoomData が返らなかった"
            stats["build_sec"] = CFAbsoluteTimeGetCurrent() - buildStart
            return stats
        }

        do {
            let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(room).write(to: bundleURL.appendingPathComponent("room.json"))
            stats["walls"] = room.walls.count
            stats["objects"] = room.objects.count
            stats["openings"] = room.doors.count + room.windows.count + room.openings.count
            stats["doors"] = room.doors.count
            stats["windows"] = room.windows.count
        } catch {
            stats["error"] = error.localizedDescription
        }
        stats["build_sec"] = CFAbsoluteTimeGetCurrent() - buildStart
        return stats
    }

    private func resume(with data: CapturedRoomData?, reason: String?) {
        guard let c = continuation else { return }
        continuation = nil
        if let reason { failure = reason }
        c.resume(returning: data)
    }
}

@available(iOS 17.0, *)
extension RoomPlanSidecar: RoomCaptureSessionDelegate {

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let walls = room.walls.count, objects = room.objects.count
        Task { @MainActor [weak self] in
            self?.liveWalls = walls
            self?.liveObjects = objects
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession,
                                    didEndWith data: CapturedRoomData,
                                    error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor [weak self] in
            self?.resume(with: data, reason: message)
        }
    }
}
