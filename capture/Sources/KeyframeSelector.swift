import ARKit
import CoreVideo
import Foundation
import simd

/// どのフレームを記録するかを決める。
///
/// 30fps を全部保存するのは容量の無駄なだけでなく**有害**で、同一視点の重複フレームは
/// 3DGS の densification を歪めて floater を増やす。狙いは実効 3〜6fps。
/// 判定条件は docs/pipeline.md §3.2。
struct KeyframeSelector {

    struct Thresholds {
        var minTranslation: Float = 0.05        // 5cm
        var minRotation: Float = 5 * .pi / 180  // 5 度
        var minConfidenceHighRatio: Double = 0.30
        /// 直近のシャープネス中央値に対する比。ブレたフレームを落とす。
        var sharpnessRatio: Double = 0.60
    }

    enum Decision {
        case accept
        case reject(String)

        var isAccepted: Bool { if case .accept = self { return true }; return false }
    }

    struct Metrics {
        var sharpness: Double
        var confidenceHighRatio: Double
    }

    var thresholds = Thresholds()

    private var lastAccepted: simd_float4x4?
    private var recentSharpness: [Double] = []
    private let sharpnessWindow = 30

    mutating func reset() {
        lastAccepted = nil
        recentSharpness.removeAll()
    }

    /// 採用可否を判定する。副作用として内部状態を更新する。
    mutating func evaluate(frame: ARFrame, metrics: Metrics, confidenceHighValue: UInt8) -> Decision {
        // シャープネス履歴は棄却したフレームも含めて更新する。
        // 部屋全体が一様に暗い場合、基準まで一緒に下がってくれないと全部落ちてしまう。
        recentSharpness.append(metrics.sharpness)
        if recentSharpness.count > sharpnessWindow { recentSharpness.removeFirst() }

        guard case .normal = frame.camera.trackingState else {
            return .reject("tracking")
        }
        guard frame.sceneDepth != nil else {
            return .reject("depth なし")
        }
        if metrics.confidenceHighRatio < thresholds.minConfidenceHighRatio {
            return .reject(String(format: "信頼度 %.0f%%", metrics.confidenceHighRatio * 100))
        }

        // 履歴が溜まるまではシャープネス判定を行わない（最初の数枚を全部落とさないため）
        if recentSharpness.count >= 10 {
            let sorted = recentSharpness.sorted()
            let median = sorted[sorted.count / 2]
            if metrics.sharpness < median * thresholds.sharpnessRatio {
                return .reject("ブレ")
            }
        }

        let transform = frame.camera.transform
        if let previous = lastAccepted {
            let dt = simd_distance(previous.columns.3.xyz, transform.columns.3.xyz)
            let dr = Self.angle(between: previous, and: transform)
            if dt < thresholds.minTranslation && dr < thresholds.minRotation {
                return .reject("移動不足")
            }
        }

        lastAccepted = transform
        return .accept
    }

    private static func angle(between a: simd_float4x4, and b: simd_float4x4) -> Float {
        let qa = simd_quatf(simd_float3x3(a.columns.0.xyz, a.columns.1.xyz, a.columns.2.xyz))
        let qb = simd_quatf(simd_float3x3(b.columns.0.xyz, b.columns.1.xyz, b.columns.2.xyz))
        let dot = abs(simd_dot(qa.vector, qb.vector))
        return 2 * acos(min(1, dot))
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

// MARK: - フレームの計測

enum FrameMetrics {

    /// Y プレーンの Laplacian 分散でシャープネスを測る。
    ///
    /// 室内スキャンでは暗所 + 歩行によるモーションブラーが splat をぼかす最大の要因なので、
    /// ここで落としておく。全画素を舐めると重いので中央領域を間引いて見る。
    static func sharpness(of pixelBuffer: CVPixelBuffer, stride step: Int = 4) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let y = base.assumingMemoryBound(to: UInt8.self)

        // 中央 50% だけを見る。周辺は歪みと露出が不安定で判定を濁らせる。
        let x0 = width / 4, x1 = width * 3 / 4
        let y0 = height / 4, y1 = height * 3 / 4
        guard x1 - x0 > 2 * step, y1 - y0 > 2 * step else { return 0 }

        var sum = 0.0
        var sumSq = 0.0
        var count = 0.0

        var row = y0 + step
        while row < y1 - step {
            var col = x0 + step
            while col < x1 - step {
                let c = Double(y[row * rowBytes + col])
                let up = Double(y[(row - step) * rowBytes + col])
                let down = Double(y[(row + step) * rowBytes + col])
                let left = Double(y[row * rowBytes + (col - step)])
                let right = Double(y[row * rowBytes + (col + step)])
                let lap = 4 * c - up - down - left - right
                sum += lap
                sumSq += lap * lap
                count += 1
                col += step
            }
            row += step
        }

        guard count > 0 else { return 0 }
        let mean = sum / count
        return max(0, sumSq / count - mean * mean)
    }

    /// 信頼度マップのうち `.high` が占める割合。
    static func confidenceHighRatio(of buffer: CVPixelBuffer, highValue: UInt8) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let p = base.assumingMemoryBound(to: UInt8.self)

        var high = 0
        for row in 0..<height {
            let offset = row * rowBytes
            for col in 0..<width where p[offset + col] >= highValue {
                high += 1
            }
        }
        return Double(high) / Double(width * height)
    }
}
