import Foundation
import simd

/// RoomPlan の出力に対する人手の訂正。
///
/// なぜ人手なのか
/// -------------
/// 実測（room-33d49373）で自動補正が二度とも誤答した。
///
/// - **箱の位置**: 椅子の箱が Z 方向に 35cm ずれ、箱の中身が机の下面と床だった。
///   占有面積を最大化する補正を試すと、正しかった机の箱まで 30cm 動いた。
/// - **開口の種別**: 幅 1736mm の掃き出し窓が `doors` に入っていた。下端 0mm は
///   掃き出し窓と矛盾せず、幅も両開き戸としてあり得るので**幾何では見分けられない**。
///
/// どちらも RoomPlan の `confidence` が `medium` だった。オペレータは部屋の中に
/// 立っているので、その場で直すのが最も確実で速い。
///
/// 形式は Python 側（`recon/mdr2colmap`）と共通で、バンドルに `fixes.json` として
/// 置く。サーバ経路でも同じ図が再現できる。
struct PlanCorrections: Codable, Equatable {
    /// 家具の箱の位置の補正（world 座標、メートル）。
    var boxes: [String: Offset] = [:]
    /// 開口の種別の訂正（`"door"` / `"window"` / `"opening"`）。
    var openings: [String: String] = [:]

    struct Offset: Codable, Equatable {
        var dx: Double = 0
        var dy: Double = 0
        var dz: Double = 0

        var x: Double { dx }
        var y: Double { dy }
        var z: Double { dz }
    }

    var isEmpty: Bool { boxes.isEmpty && openings.isEmpty }

    static let fileName = "fixes.json"

    // MARK: 入出力

    /// バンドルから読む。無ければ空。
    static func load(from bundleURL: URL) -> PlanCorrections {
        let url = bundleURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return .init() }
        // `_note` などの追加キーがあっても落とさない
        guard let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return .init() }
        var out = PlanCorrections()
        if let boxes = obj["boxes"] as? [String: [String: Any]] {
            for (k, v) in boxes {
                out.boxes[k] = Offset(dx: (v["dx"] as? Double) ?? 0,
                                      dy: (v["dy"] as? Double) ?? 0,
                                      dz: (v["dz"] as? Double) ?? 0)
            }
        }
        if let openings = obj["openings"] as? [String: String] {
            out.openings = openings
        }
        return out
    }

    /// バンドルに書く。**理由も一緒に残す。** 数値だけでは後から検算できない。
    func write(to bundleURL: URL, note: String) -> Bool {
        var boxesOut: [String: Any] = [:]
        for (k, v) in boxes {
            var d: [String: Any] = [:]
            if v.dx != 0 { d["dx"] = v.dx }
            if v.dy != 0 { d["dy"] = v.dy }
            if v.dz != 0 { d["dz"] = v.dz }
            boxesOut[k] = d
        }
        let obj: [String: Any] = [
            "_note": note,
            "boxes": boxesOut,
            "openings": openings,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: bundleURL.appendingPathComponent(PlanCorrections.fileName))
            return true
        } catch {
            return false
        }
    }
}
