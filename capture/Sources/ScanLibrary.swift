import Foundation
import RoomPlan
import simd

/// Documents にある過去の MDR バンドルを一覧する。
///
/// 端末で見返せるようにする理由
/// -------------------------
/// 平面図は `room.json` だけで作れる（`FloorPlan` 参照）。訂正も端末側で行う
/// ので、**撮り直しに来る前に過去のスキャンを開いて直せる**必要がある。
/// 3D は焼き込み時に `mesh.usdz` を書いているので Quick Look で開ける。
final class ScanLibrary: ObservableObject {

    struct Scan: Identifiable, Equatable {
        let url: URL
        var id: URL { url }

        /// バンドル名（`room-33d49373.mdr`）。
        var name: String { url.lastPathComponent }
        /// 表示名（拡張子を落としたもの）。
        var title: String { url.deletingPathExtension().lastPathComponent }

        var createdAt: Date?
        var frameCount: Int?
        var durationSec: Double?
        var deviceModel: String?
        var worldAlignment: String?
        var headingUsable: Bool?

        var hasRoom = false        // room.json（平面図を作れる）
        var hasUSDZ = false        // mesh.usdz（Quick Look で開ける）
        var hasGLB = false
        var hasFixes = false       // 人手の訂正が保存済み

        // 焼き込みの素性（bake.json）。**遅かった撮影を後から見分けるため。**
        var bakeElapsedSec: Double?
        var bakeUnwrapSec: Double?
        var bakeTriangles: Int?
        var bakeConfiguration: String?
        var bakeThermal: String?

        /// UV 展開が基準の何倍か。3 倍を超えたら最適化なしか熱を疑う。
        var bakeSlowdown: Double? {
            guard let u = bakeUnwrapSec, let t = bakeTriangles else { return nil }
            return BuildInfo.Metrics.slowdown(unwrapSec: u, triangles: t)
        }
        /// バイト数。走査に時間がかかるので後から埋める。
        var byteSize: Int64?

        /// 平面図に描く北。`.gravityAndHeading` で撮れていたときだけ。
        var north: SIMD2<Double>? {
            guard worldAlignment == "gravityAndHeading", headingUsable == true else {
                return nil
            }
            // world は +X が東 / +Z が南。北は -Z。
            return SIMD2(0, -1)
        }

        var roomJSONURL: URL { url.appendingPathComponent("room.json") }
        var usdzURL: URL { url.appendingPathComponent("mesh.usdz") }

        /// `room.json` から `CapturedRoom` を復元する。**`Codable` なのでそのまま戻せる。**
        @available(iOS 17.0, *)
        func loadRoom() throws -> CapturedRoom {
            let data = try Data(contentsOf: roomJSONURL)
            return try JSONDecoder().decode(CapturedRoom.self, from: data)
        }
    }

    @Published private(set) var scans: [Scan] = []
    @Published private(set) var isLoading = false

    private let queue = DispatchQueue(label: "madoriba.library", qos: .utility)

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 走査するディレクトリ。既定は Documents。テストで差し替える。
    var root: URL = ScanLibrary.documentsURL

    /// 一覧を読み直す。新しい順。
    func reload() {
        isLoading = true
        let root = self.root
        queue.async { [weak self] in
            let found = ScanLibrary.enumerate(in: root)
            DispatchQueue.main.async {
                self?.scans = found
                self?.isLoading = false
            }
            // 容量は走査が重いので後から埋める。一覧の表示を待たせない。
            for scan in found {
                let size = ScanLibrary.size(of: scan.url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let i = self.scans.firstIndex(where: { $0.url == scan.url }) {
                        self.scans[i].byteSize = size
                    }
                }
            }
        }
    }

    func delete(_ scan: Scan) {
        try? FileManager.default.removeItem(at: scan.url)
        scans.removeAll { $0.url == scan.url }
    }

    // MARK: 走査

    static func enumerate(in root: URL) -> [Scan] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var out: [Scan] = []
        for url in entries where url.pathExtension == "mdr" {
            var scan = Scan(url: url)
            scan.hasRoom = fm.fileExists(atPath: scan.roomJSONURL.path)
            scan.hasUSDZ = fm.fileExists(atPath: scan.usdzURL.path)
            scan.hasGLB = fm.fileExists(
                atPath: url.appendingPathComponent("mesh.glb").path)
            scan.hasFixes = fm.fileExists(
                atPath: url.appendingPathComponent(PlanCorrections.fileName).path)

            if let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
               let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                scan.frameCount = m["frame_count"] as? Int
                scan.durationSec = m["duration_sec"] as? Double
                scan.worldAlignment = m["world_alignment"] as? String
                if let h = m["heading"] as? [String: Any] {
                    scan.headingUsable = h["usable"] as? Bool
                }
                if let d = m["device"] as? [String: Any] {
                    scan.deviceModel = d["model"] as? String
                }
                if let s = m["created_at"] as? String {
                    scan.createdAt = ScanLibrary.parseDate(s)
                }
            }
            if let data = try? Data(contentsOf: url.appendingPathComponent("bake.json")),
               let b = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                scan.bakeElapsedSec = b["elapsed_sec"] as? Double
                scan.bakeTriangles = b["triangles"] as? Int
                scan.bakeConfiguration = b["build_configuration"] as? String
                scan.bakeThermal = b["thermal_state"] as? String
                if let stages = b["stages_sec"] as? [String: Any] {
                    scan.bakeUnwrapSec = stages["unwrap"] as? Double
                }
            }
            if scan.createdAt == nil {
                scan.createdAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            }
            out.append(scan)
        }
        return out.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
    }

    private static func size(of url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
            options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let s = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(s)
            }
        }
        return total
    }

    /// `created_at` は小数秒付きの場合とない場合がある（実データは
    /// `2026-09-07T09:40:25Z`）。両方試す。片方だけだと日付が消えて
    /// 並び順が壊れる。
    private static func parseDate(_ s: String) -> Date? {
        let variants: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
        ]
        for options in variants {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
