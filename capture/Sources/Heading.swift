import CoreLocation
import Foundation

/// 真北を取る。`ARWorldTrackingConfiguration.worldAlignment = .gravityAndHeading`
/// のための前提を整え、**取れたかどうかを記録する**。
///
/// なぜ記録が要るか
/// ---------------
/// `.gravityAndHeading` は磁気コンパスに依存する。位置情報の許可が無ければ
/// ARKit は方位を確立できず、`.gravity` と同じ任意の向きになる。屋内では
/// 鉄骨や家電で磁場が乱れ、許可があっても精度が落ちる。
///
/// **取れていないのに方位記号を描くと、販売図面に嘘の方位が載る。** 許可の
/// 状態と精度をバンドルに残し、使えるときだけ北を描く。
///
/// 座標の約束
/// ---------
/// `.gravityAndHeading` の world 座標は **+X が東、+Y が上、+Z が南**。
/// したがって北は `(0, 0, -1)`。平面図は +Z を画面下に取るので、北は画面上を
/// 指す。部屋の壁が斜めに描かれるようになり、それが正しい向きになる。
final class Heading: NSObject, ObservableObject, CLLocationManagerDelegate {

    /// 使える精度の上限（度）。磁気コンパスの `headingAccuracy` はこの値以下を要求する。
    ///
    /// 負値は「無効」を意味する仕様なので、まず符号を見る。上限 20 度は
    /// 方位記号の向きとして許せる範囲（8 方位の 1 区画 45 度の半分未満）。
    static let accuracyLimit: Double = 20.0

    struct Report {
        var available: Bool
        var authorization: String
        var accuracyDeg: Double?
        var trueHeadingDeg: Double?
        var magneticHeadingDeg: Double?

        /// 方位を採用してよいか。
        var isUsable: Bool {
            guard available, authorization == "authorizedWhenInUse"
                    || authorization == "authorizedAlways" else { return false }
            guard let a = accuracyDeg, a >= 0, a <= Heading.accuracyLimit else { return false }
            return true
        }

        var json: [String: Any] {
            var out: [String: Any] = ["available": available,
                                      "authorization": authorization,
                                      "usable": isUsable]
            if let a = accuracyDeg { out["accuracy_deg"] = a }
            if let t = trueHeadingDeg { out["true_heading_deg"] = t }
            if let m = magneticHeadingDeg { out["magnetic_heading_deg"] = m }
            return out
        }
    }

    @Published private(set) var report = Report(
        available: CLLocationManager.headingAvailable(),
        authorization: "notDetermined",
        accuracyDeg: nil, trueHeadingDeg: nil, magneticHeadingDeg: nil)

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        report.authorization = Heading.name(manager.authorizationStatus)
    }

    /// 許可を求め、方位の更新を始める。**`ARSession.run` より先に呼ぶ。**
    /// 後から呼ぶと、セッション開始時に ARKit が方位を確立できない。
    func start() {
        guard CLLocationManager.headingAvailable() else { return }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingHeading()
    }

    func stop() { manager.stopUpdatingHeading() }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let name = Heading.name(m.authorizationStatus)
        DispatchQueue.main.async { self.report.authorization = name }
        if m.authorizationStatus == .authorizedWhenInUse
            || m.authorizationStatus == .authorizedAlways {
            m.startUpdatingHeading()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        DispatchQueue.main.async {
            self.report.accuracyDeg = h.headingAccuracy
            // trueHeading は位置情報が取れないと負値になる。磁北は常に入る。
            self.report.trueHeadingDeg = h.trueHeading >= 0 ? h.trueHeading : nil
            self.report.magneticHeadingDeg = h.magneticHeading
        }
    }

    private static func name(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown"
        }
    }
}
