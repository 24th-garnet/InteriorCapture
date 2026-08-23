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
@MainActor
final class FrameStore {

    /// 焼き込み用 RGB の長辺。A12Z のメモリ（6GB）を考慮した上限。
    static let bakeImageWidth = 960

    private let device: MTLDevice
    private(set) var frames: [BakedFrame] = []

    /// 上限。1 フレームあたり RGB 960x720 BGRA (2.6MB) + 深度 (0.2MB) で約 2.8MB。
    /// 250 枚で約 700MB。A12Z の 6GB に対して現実的な範囲に収める。
    private let maxFrames: Int

    init(device: MTLDevice, maxFrames: Int = 250) {
        self.device = device
        self.maxFrames = maxFrames
    }

    var isFull: Bool { frames.count >= maxFrames }

    func reset() { frames.removeAll() }

    /// ARFrame から焼き込み用のテクスチャ一式を作る。
    ///
    /// `worldToCamera` はここで ARKit → OpenCV 規約に変換する。
    /// MDR バンドルには生値を保存する方針（変換は recon 側に一元化）だが、
    /// オンデバイス焼き込みは recon を経由しないので、ここで変換する必要がある。
    func append(frame: ARFrame, sharpness: Float, encoder: ImageEncoder) {
        guard !isFull, let depth = frame.sceneDepth else { return }

        let scale = Float(Self.bakeImageWidth) / Float(CVPixelBufferGetWidth(frame.capturedImage))
        guard let rgb = encoder.downscaledTexture(from: frame.capturedImage,
                                                  width: Self.bakeImageWidth,
                                                  device: device),
              let d = Self.texture(from: depth.depthMap, format: .r32Float, device: device),
              let c = depth.confidenceMap.flatMap({
                  Self.texture(from: $0, format: .r8Uint, device: device)
              })
        else { return }

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
