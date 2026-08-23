import Foundation
import RoomPlan
import simd

/// Apple RoomPlan による構造化スキャン。
///
/// LiDAR メッシュから自前で壁を抽出する経路（recon/floorplan.py）とは別系統で、
/// Apple の ML が壁・ドア・窓・開口・家具を**型付きオブジェクト**として返す。
/// 点の集まりから幾何を当てるより素直なので、間取り用途では有力。
///
/// 比較のため MDR バンドルと**同じ部屋を別セッションで撮る**。
/// ARWorldTrackingConfiguration と RoomCaptureSession は同時に走らせられないため、
/// 1 回のスキャンで両方を得ることはできない。
@available(iOS 16.0, *)
final class RoomPlanCapture: NSObject, ObservableObject {

    enum State: Equatable {
        case unsupported
        case idle
        case scanning
        case processing
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var state: State
    @Published private(set) var wallCount = 0
    @Published private(set) var objectCount = 0

    /// RoomCaptureView が自前で作るセッション。`captureSession` は get-only なので
    /// こちらから差し込むことはできず、ビューが作ったものを受け取って delegate を張る。
    private(set) weak var captureSession: RoomCaptureSession?

    override init() {
        state = RoomCaptureSession.isSupported ? .idle : .unsupported
        super.init()
    }

    func attach(to session: RoomCaptureSession) {
        captureSession = session
        session.delegate = self
    }

    func start() {
        guard let captureSession, state == .idle else { return }
        wallCount = 0
        objectCount = 0
        state = .scanning
        captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func stop() {
        guard state == .scanning else { return }
        state = .processing
        captureSession?.stop()
    }

    func acknowledge() {
        if state != .unsupported { state = .idle }
    }

    private func export(_ room: CapturedRoom) {
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let id = String(UUID().uuidString.prefix(8)).lowercased()
            let dir = documents.appendingPathComponent("roomplan-\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // USDZ: 3D モデルとして開ける。Quick Look でそのまま見られる。
            try room.export(to: dir.appendingPathComponent("room.usdz"))

            // JSON: 壁・開口の寸法を数値で取り出せる形。自前の間取り抽出と突き合わせる。
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(room).write(to: dir.appendingPathComponent("room.json"))

            state = .finished(dir)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

@available(iOS 16.0, *)
extension RoomPlanCapture: RoomCaptureSessionDelegate {

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        // 進捗表示用。撮影中にどれだけ構造が取れたかが分かる。
        DispatchQueue.main.async {
            self.wallCount = room.walls.count
            self.objectCount = room.objects.count
        }
    }

    func captureSession(
        _ session: RoomCaptureSession,
        didEndWith data: CapturedRoomData,
        error: Error?
    ) {
        if let error {
            DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            return
        }
        Task { @MainActor in
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects])
                    .capturedRoom(from: data)
                self.export(room)
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }
}
