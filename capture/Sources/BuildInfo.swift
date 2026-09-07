import Foundation

/// ビルドと実行環境の素性。**性能を語る前に構成を記録する。**
///
/// なぜ必要になったか
/// ----------------
/// `-configuration Debug` で端末に入れたことに気づかず、焼き込みが遅くなった
/// 原因を探すことになった。Debug は `GCC_OPTIMIZATION_LEVEL = 0` で、焼き込み
/// 時間の 97% を占める xatlas（外部の C++）が最適化なしになる。実測で
/// **6.5 倍**（同じ 148,897 面で -O0 49.62 秒 / -O2 7.68 秒）。
///
/// いまは `project.yml` の `compilerFlags` で xatlas を構成に関わらず `-O2` に
/// 固定したのでこの罠は塞がれているが、**遅さを構成の記憶に頼らず数値で
/// 検出できるようにしておく**（`Metrics.unwrapMicrosecondsPerTriangle`）。
enum BuildInfo {

    /// Swift のビルド構成。`SWIFT_ACTIVE_COMPILATION_CONDITIONS` に依存する。
    static var configuration: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    /// xatlas の最適化。`project.yml` の `compilerFlags` で構成に関わらず
    /// `-O2` を後付けしている（Xcode は構成の設定を先に渡すので後勝ち）。
    ///
    /// **ここは宣言であって測定ではない。** 実際に速いかどうかは
    /// `Metrics.unwrapMicrosecondsPerTriangle` で判断する。
    static let xatlasFlags = "-w -O2"

    static var thermalStateName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static var summary: String {
        "build: \(configuration)  xatlas: \(xatlasFlags)  thermal: \(thermalStateName)"
    }

    /// 焼き込みが遅いかを**構成の記憶に頼らず**判断するための指標。
    enum Metrics {
        /// 面 1 枚あたりの UV 展開時間（マイクロ秒）。
        ///
        /// 面数はスキャンごとに変わるので、秒数の比較では速いか遅いか分からない。
        /// 面数で割れば端末が同じなら比較できる。
        ///
        /// 実測の基準（iPad8,11 / 最適化あり）: 148,897 面で 13.91 秒
        /// = **93.4 µs/面**。同じ端末で数倍になっていれば最適化なしか
        /// 熱による絞りを疑う。
        static func unwrapMicrosecondsPerTriangle(unwrapSec: Double,
                                                 triangles: Int) -> Double? {
            guard triangles > 0 else { return nil }
            return unwrapSec * 1_000_000 / Double(triangles)
        }

        /// iPad8,11 で最適化ありのときの実測値。
        static let referenceUnwrapMicrosecondsPerTriangle = 93.4

        /// 基準の何倍か。3 倍を超えたら異常として扱う。
        static func slowdown(unwrapSec: Double, triangles: Int) -> Double? {
            guard let v = unwrapMicrosecondsPerTriangle(unwrapSec: unwrapSec,
                                                        triangles: triangles) else {
                return nil
            }
            return v / referenceUnwrapMicrosecondsPerTriangle
        }

        /// 異常とみなすしきい値。**端末が違えば基準も違う**ので、
        /// 3 倍という緩い値にしてある（-O0 は 6.5 倍だった）。
        static let slowdownAlarm = 3.0
    }
}
