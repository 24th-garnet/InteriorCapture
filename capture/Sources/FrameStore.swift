import ARKit
import Metal
import simd

/// 焼き込み用にキーフレームを GPU 側で保持する。
///
/// MDR バンドルへの書き出しとは別に、オンデバイス焼き込み用のテクスチャを作る。
/// ディスクに書いた JPEG を読み直すと、605 枚のデコードだけで数十秒かかるため。
///
/// メモリ量を抑えるため、焼き込み用には**縮小した RGB** を持つ。
/// Mac 側の実測で「テクスチャの実効解像度は 4.6mm/テクセルで、
/// アトラスを 4096^2 にしても改善しない」ことが分かっており、
/// フル解像度の RGB を保持する必要はない。
///
/// - Important: `append` は ARSession のデリゲートキューから**同期的に**呼ぶこと。
///   ARKit は ARFrame のピクセルバッファをプールから再利用するため、
///   非同期タスクに逃がして後から読むと、別フレームの内容になっている恐れがある。
final class FrameStore {

    /// 焼き込み用 RGB の長辺。A12Z のメモリ（6GB）を考慮した上限。
    static let bakeImageWidth = 960

    private let device: MTLDevice
    private(set) var frames: [BakedFrame] = []
    /// デバッグ出力の保存先。設定されていれば最初の数フレームを PNG に落とす。
    var debugDirectory: URL?
    private var debugWritten = 0

    /// 上限。1 フレームあたり RGB 960x720 BGRA (2.76MB) + 深度 (0.10MB)
    /// + 信頼度 (0.05MB) で約 2.9MB。
    ///
    /// **150 枚にする。** 実測（bake.json 6 件）で、保持枚数が 150 を超えると
    /// UV 展開が崩れる。面数ではない:
    ///
    ///     枚数  展開 s   面数     未着色
    ///      109   16.0    98,108    6.2%
    ///      138   15.5   168,407    6.8%
    ///      146   13.9   148,897    8.2%
    ///      148   14.9   205,050   13.2%    <- 最多の面数でも 15 秒
    ///      177   36.2   178,725    6.1%
    ///      235  178.4   192,403    8.9%    <- 12 倍。同じメッシュは Mac で 14.35 秒
    ///
    /// 148 枚以下は面数 98k〜205k にわたって常に 14〜16.5 秒。**枚数だけが効く。**
    /// 保持テクスチャ（235 枚で 682MB）が xatlas の作業領域を圧迫し、
    /// 圧縮・スワップに入るためと見ている（`unwrap_detail` の残メモリで確認中）。
    /// 250 枚では焼き込みが完了せずアプリが終了した実測もある。
    ///
    /// **枚数を減らしても品質は落ちない。** 未着色率は 109 枚の 6.2% が最良で、
    /// 235 枚は 8.9% とむしろ悪い。被覆は歩き方で決まり、枚数では決まらない。
    private let maxFrames: Int

    /// 現在の間引き間隔。上限に達するたびに倍になる。
    private var stride = 1
    /// 間引き直後の受け入れ位相。これを合わせないと、次に採用されるまで
    /// stride 分だけ待つことになり、保持数が上限より目減りする。
    private var phase = 0

    init(device: MTLDevice, maxFrames: Int = 150) {
        self.device = device
        self.maxFrames = maxFrames
    }

    private func keepEveryOther() {
        var kept: [BakedFrame] = []
        kept.reserveCapacity(frames.count / 2 + 1)
        for (i, f) in frames.enumerated() where i % 2 == 0 { kept.append(f) }
        frames = kept
        stride *= 2
    }

    /// 取り込んだ総数。間引き後の保持数（`frames.count`）とは別。
    private(set) var seenCount = 0

    func reset() { frames.removeAll(); seenCount = 0 }

    /// ARFrame から焼き込み用のテクスチャ一式を作る。
    ///
    /// `worldToCamera` はここで ARKit → OpenCV 規約に変換する。
    /// MDR バンドルには生値を保存する方針（変換は recon 側に一元化）だが、
    /// オンデバイス焼き込みは recon を経由しないので、ここで変換する必要がある。
    /// 上限に達したら、**間引いて全体から均等に残す**。
    ///
    /// 単純に先頭で打ち切ると、撮影は外周を何周もするため部屋の一部しか
    /// 写らない。実測では先頭 250 枚だと未着色が 14.4%、
    /// 全体から均等に 250 枚なら 7.8%（全 507 枚の 7.4% とほぼ同じ）。
    func append(frame: ARFrame, sharpness: Float, encoder: ImageEncoder) {
        guard let depth = frame.sceneDepth else { return }
        seenCount += 1

        if frames.count >= maxFrames {
            // 偶数番目を捨てて半分にし、以降は 1 枚おきに受け入れる。
            // これを繰り返すと、撮影が長引いても全体に散った標本が保たれる。
            keepEveryOther()
            phase = seenCount % stride
        }
        if stride > 1 && (seenCount % stride) != phase { return }

        let scale = Float(Self.bakeImageWidth) / Float(CVPixelBufferGetWidth(frame.capturedImage))
        guard let rgb = encoder.downscaledTexture(from: frame.capturedImage,
                                                  width: Self.bakeImageWidth,
                                                  device: device),
              let d = Self.texture(from: depth.depthMap, format: .r32Float, device: device),
              let c = depth.confidenceMap.flatMap({
                  Self.texture(from: $0, format: .r8Uint, device: device)
              })
        else { return }

        // GPU に渡している入力が正しいかは現物を見るのが確実。最初の数枚だけ落とす。
        if let dir = debugDirectory, debugWritten < 3 {
            TextureDebug.writePNG(rgb, to: dir.appendingPathComponent("debug_rgb_\(debugWritten).png"))
            TextureDebug.writeDepthPNG(d, to: dir.appendingPathComponent("debug_depth_\(debugWritten).png"))
            debugWritten += 1
        }

        let k = frame.camera.intrinsics
        frames.append(BakedFrame(
            rgb: rgb, depth: d, confidence: c,
            worldToCamera: Self.worldToCamera(frame.camera.transform),
            fx: k.columns.0.x * scale, fy: k.columns.1.y * scale,
            cx: k.columns.2.x * scale, cy: k.columns.2.y * scale,
            sharpness: sharpness
        ))
    }

    /// ARKit の camera->world から OpenCV 規約の world->camera を得る。
    ///
    /// ARKit は X 右 / Y 上 / Z 後（カメラは -Z を向く）、
    /// OpenCV は X 右 / Y 下 / Z 前。カメラ軸の Y と Z を反転して逆行列を取る。
    /// recon/mdr2colmap/colmap.py と同じ規約。
    static func worldToCamera(_ c2wARKit: simd_float4x4) -> simd_float4x4 {
        let flip = simd_float4x4(diagonal: SIMD4(1, -1, -1, 1))
        return (c2wARKit * flip).inverse
    }

    private static func texture(from buffer: CVPixelBuffer,
                                format: MTLPixelFormat,
                                device: MTLDevice) -> MTLTexture? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0, withBytes: base, bytesPerRow: stride)
        return tex
    }
}
