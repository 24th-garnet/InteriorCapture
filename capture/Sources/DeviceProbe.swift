import ARKit
import Foundation

/// 起動時に実機の素性を確定させる。
///
/// `capture/README.md` に挙げた「Phase 1 冒頭で実機確認すること」を自動化したもの。
/// A12Z の iPad Pro 2020 は Scaniverse ですら splat 非対応の世代なので、
/// ARKit がどこまで返してくるかは想定ではなく実測で押さえる。
enum DeviceProbe {

    struct Report {
        var model: String
        var os: String
        var hasLiDAR: Bool
        var supportsSceneDepth: Bool
        var supportsSceneReconstruction: Bool
        var videoFormats: [ARConfiguration.VideoFormat]
        var highResFormat: ARConfiguration.VideoFormat?

        var summary: String {
            var out = ["device: \(model)  os: \(os)"]
            out.append("LiDAR: \(hasLiDAR)  sceneDepth: \(supportsSceneDepth)  mesh: \(supportsSceneReconstruction)")
            out.append("videoFormats:")
            for f in videoFormats {
                out.append("  \(Int(f.imageResolution.width))x\(Int(f.imageResolution.height)) @\(f.framesPerSecond)")
            }
            if let h = highResFormat {
                out.append("highResolutionFrameCapturing: \(Int(h.imageResolution.width))x\(Int(h.imageResolution.height))")
            } else {
                // A12Z では nil の可能性があると事前調査で判明している。
                // nil なら 12MP 静止画の混ぜ込みは諦める（致命的ではない）。
                out.append("highResolutionFrameCapturing: なし (nil)")
            }
            return out.joined(separator: "\n")
        }
    }

    static func run() -> Report {
        var sys = utsname()
        uname(&sys)
        let model = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        let highRes: ARConfiguration.VideoFormat?
        if #available(iOS 16.0, *) {
            highRes = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing
        } else {
            highRes = nil
        }

        return Report(
            model: model,
            os: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            hasLiDAR: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            supportsSceneDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            supportsSceneReconstruction: ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification),
            videoFormats: ARWorldTrackingConfiguration.supportedVideoFormats,
            highResFormat: highRes
        )
    }

    /// 記録に使うビデオ形式を選ぶ。
    ///
    /// A12Z は ARKit の 4K に非対応（4K は iPhone 11+ または M1 iPad Pro 以降）なので
    /// 1920x1440 が上限。60fps は熱予算を食うだけでキーフレーム選別後の枚数は変わらないので選ばない。
    static func preferredFormat(from formats: [ARConfiguration.VideoFormat]) -> ARConfiguration.VideoFormat? {
        let at30 = formats.filter { $0.framesPerSecond == 30 }
        let pool = at30.isEmpty ? formats : at30
        return pool.max { a, b in
            a.imageResolution.width * a.imageResolution.height
                < b.imageResolution.width * b.imageResolution.height
        }
    }
}
