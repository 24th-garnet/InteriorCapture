import ARKit
import Foundation
import RoomPlan

/// MDR 撮影と同じ `ARSession` の上で RoomPlan を走らせ、構造化された部屋を得る。
///
/// なぜ同居させるか
/// ---------------
/// 別セッションで 2 回撮る方式でも間取り図は作れるが、
///
/// - 撮影時間が倍になる（71 秒 × 2）
/// - **RoomPlan の部屋座標と MDR の ARKit world 座標が無関係になる**
///
/// 後者が本質的に困る。間取り図を 3D モデルに重ねる（平面図上の位置から
/// 該当 station へ飛ぶなど）には位置合わせが必要になり、それは後から
/// 精度良く付け足すのが難しい。同一セッションなら無料で一致する。
///
/// 実測（30 秒 × 各条件、`CoexistProbe`）
/// -------------------------------------
///                     なし        あり＋深度再適用
///   採用フレーム        160 枚      166 枚
///   映像               1920x1440   1920x1440
///   メッシュ頂点         21,622      21,741
///   メモリ              498MB       553MB
///   発熱               nominal     nominal
///   RoomPlan           —           壁 4 / 物体 3
///
/// **劣化しない。** 懸念していた採用フレームの減少も発熱も起きなかった。
///
/// 深度が落ちる問題
/// ---------------
/// `RoomCaptureSession.run(configuration:)` は共有セッションを**自前の設定で
/// 上書きし、`frameSemantics` から `.sceneDepth` を落とす**。深度付きフレームが
/// 0 枚になり MDR が成立しなくなる。しかも挙動が一貫せず、計測の順序を
/// 変えると有効になったりする（競合状態がある）。
///
/// 対処として起動 `depthReapplyDelay` 秒後に深度だけ戻す。`resetTracking` は
/// 付けない（RoomPlan が積み上げた状態を壊す）。実測で 836/881 枚 = 95% が
/// 深度付きになり、欠けるのは冒頭の 1.5 秒だけ。
///
/// **撮影開始前から回しておく**ことでその空白を隠す。録画ボタンを押す時点では
/// 再適用が済んでいるので、記録されるフレームはすべて深度付きになる。
@available(iOS 17.0, *)
final class RoomScan {

    /// RoomPlan 起動から深度を戻すまでの待ち。短すぎると上書き前に走って無意味になる。
    static let depthReapplyDelay: TimeInterval = 2.0

    private(set) var latestRoom: CapturedRoom?
    private(set) var lastError: String?

    private weak var session: ARSession?
    private var roomSession: RoomCaptureSession?
    private var delegateBox: DelegateBox?
    private var finalizeContinuation: CheckedContinuation<CapturedRoomData?, Never>?

    var wallCount: Int { latestRoom?.walls.count ?? 0 }
    var objectCount: Int { latestRoom?.objects.count ?? 0 }
    var isRunning: Bool { roomSession != nil }

    /// 既存の `ARSession` の上で開始する。設定は呼び出し側が済ませておくこと。
    func start(on session: ARSession) {
        guard RoomCaptureSession.isSupported, roomSession == nil else { return }
        self.session = session

        let box = DelegateBox(owner: self)
        let rs = RoomCaptureSession(arSession: session)
        rs.delegate = box
        delegateBox = box
        roomSession = rs

        var config = RoomCaptureSession.Configuration()
        // 音声と画面のコーチングは我々の UI と衝突するので切る。
        config.isCoachingEnabled = false
        rs.run(configuration: config)

        reapplyDepth(after: Self.depthReapplyDelay)
    }

    /// RoomPlan に奪われた `.sceneDepth` を戻す。
    private func reapplyDepth(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let session = self.session,
                  let config = session.configuration as? ARWorldTrackingConfiguration
            else { return }
            guard !config.frameSemantics.contains(.sceneDepth) else { return }
            config.frameSemantics.insert(.sceneDepth)
            session.run(config, options: [])
        }
    }

    /// 停止して最終結果を返す。`RoomBuilder` は数秒かかる。
    ///
    /// ARSession は止めない（`pauseARSession: false`）。MDR の焼き込みが
    /// メッシュとフレームを使うので、こちらの都合で落としてはいけない。
    func finish() async -> CapturedRoom? {
        guard let rs = roomSession else { return latestRoom }
        let data: CapturedRoomData? = await withCheckedContinuation { cont in
            finalizeContinuation = cont
            rs.stop(pauseARSession: false)
        }
        roomSession = nil
        delegateBox = nil

        guard let data else { return latestRoom }
        do {
            let room = try await RoomBuilder(options: [.beautifyObjects])
                .capturedRoom(from: data)
            latestRoom = room
            return room
        } catch {
            lastError = error.localizedDescription
            // 途中の didUpdate で受け取った部屋は使える。完全に失うより良い。
            return latestRoom
        }
    }

    /// バンドルに書き出す。`CapturedRoom` は Codable なのでそのまま JSON にできる。
    ///
    /// 間取り図の生成は Mac 側（`recon/`）で行う。壁・ドア・窓が
    /// `transform` と `dimensions` を持つパラメトリックな形で入っているので、
    /// 真上から見た線分は直接求まる（投影もラスタライズも要らない）。
    @discardableResult
    func write(_ room: CapturedRoom, to bundleURL: URL) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(room) else { return false }
        do {
            try data.write(to: bundleURL.appendingPathComponent("room.json"))
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    fileprivate func handle(room: CapturedRoom) { latestRoom = room }
    fileprivate func handle(error: Error) { lastError = error.localizedDescription }

    fileprivate func handleEnd(data: CapturedRoomData?, error: Error?) {
        if let error { lastError = error.localizedDescription }
        finalizeContinuation?.resume(returning: data)
        finalizeContinuation = nil
    }
}

/// `RoomCaptureSessionDelegate` は nonisolated なので、`RoomScan` 本体に
/// 直接適合させると actor 分離の警告が出る。受け取りだけを担う箱に分ける。
@available(iOS 17.0, *)
private final class DelegateBox: NSObject, RoomCaptureSessionDelegate {
    weak var owner: RoomScan?

    init(owner: RoomScan) {
        self.owner = owner
        super.init()
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        owner?.handle(room: room)
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {}

    func captureSession(_ session: RoomCaptureSession,
                        didEndWith data: CapturedRoomData, error: Error?) {
        owner?.handleEnd(data: data, error: error)
    }

    func captureSession(_ session: RoomCaptureSession, didFailWith error: Error) {
        owner?.handle(error: error)
        owner?.handleEnd(data: nil, error: error)
    }
}
