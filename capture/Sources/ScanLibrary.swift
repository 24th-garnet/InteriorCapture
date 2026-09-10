import Foundation

/// Documents にある過去の MDR バンドルを一覧する。
///
/// **端末側は 3D 生成に集中する**（当初の設計）。ここでできるのは、
/// 焼き込んだ 3D を Quick Look で見返すことと、焼き込みの所要時間を
/// 確かめること。間取り図はサーバ側（`recon/`）で作る。
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

        var hasUSDZ = false        // mesh.usdz（Quick Look で開ける）
        var hasVertexColorUSDZ = false   // mesh_vc.usdz（頂点カラー版）
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


        var usdzURL: URL { url.appendingPathComponent("mesh.usdz") }
        var vertexColorUSDZURL: URL { url.appendingPathComponent("mesh_vc.usdz") }
        /// 頂点カラー版の焼き込み秒数（bake.json の `vertex_color`）。
        var vertexColorSec: Double?

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
            scan.hasUSDZ = fm.fileExists(atPath: scan.usdzURL.path)
            scan.hasVertexColorUSDZ = fm.fileExists(atPath: scan.vertexColorUSDZURL.path)
            scan.hasGLB = fm.fileExists(
                atPath: url.appendingPathComponent("mesh.glb").path)
            scan.hasFixes = fm.fileExists(
                atPath: url.appendingPathComponent("fixes.json").path)

            if let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
               let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                scan.frameCount = m["frame_count"] as? Int
                scan.durationSec = m["duration_sec"] as? Double
                scan.worldAlignment = m["world_alignment"] as? String
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
                if let vc = b["vertex_color"] as? [String: Any] {
                    scan.vertexColorSec = vc["elapsed_sec"] as? Double
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
