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
            // 性能の話をするときに構成が分からないと原因を追えない。
            out.append(BuildInfo.summary)
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
    /// 採用する映像の横幅の上限。
    ///
    /// **iPhone を対象に入れると 4K が選ばれる。** ARKit は iPhone 11 Pro 以降で
    /// 3840x2160 を提供するが、焼き込みは `FrameStore.bakeImageWidth`（960）へ
    /// 縮小するので端末側の画質は 1 ミリも上がらない。上がるのは JPEG の
    /// 書き出し負荷とバンドル容量だけで、採用フレームが減れば未着色が増える。
    /// iPad で選ばれてきた 1920x1440 はこの上限を通る。
    static let maxVideoWidth = 1920

    static func preferredFormat(from formats: [ARConfiguration.VideoFormat]) -> ARConfiguration.VideoFormat? {
        let sizes = formats.map {
            (w: Int($0.imageResolution.width), h: Int($0.imageResolution.height),
             fps: $0.framesPerSecond)
        }
        return pickFormat(from: sizes).map { formats[$0] }
    }

    /// 採用する添字を返す。`ARConfiguration.VideoFormat` は生成できないので、
    /// 判断の部分だけ切り出してテストできるようにする。
    static func pickFormat(from sizes: [(w: Int, h: Int, fps: Int)]) -> Int? {
        guard !sizes.isEmpty else { return nil }
        let indices = sizes.indices
        func best(_ pool: [Int]) -> Int? {
            pool.max { sizes[$0].w * sizes[$0].h < sizes[$1].w * sizes[$1].h }
        }
        let at30 = indices.filter { sizes[$0].fps == 30 }
        let pool = at30.isEmpty ? Array(indices) : at30
        let capped = pool.filter { sizes[$0].w <= maxVideoWidth }
        // 上限に収まるものが無ければ、一番小さいものを採る（4K しか無い機種）。
        return best(capped) ?? pool.min { sizes[$0].w * sizes[$0].h < sizes[$1].w * sizes[$1].h }
    }
}
