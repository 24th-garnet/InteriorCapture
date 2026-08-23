import CoreImage
import CoreVideo
import Foundation
import Metal

/// `ARFrame.capturedImage`（420 YpCbCr 二平面）を JPEG にする。
///
/// vImage で YCbCr→BGRA を手組みするより CIContext に任せた方が短く、GPU で走る。
/// 画像は**センサ native の向きのまま**扱い、回転も EXIF Orientation の付与もしない
/// （`intrinsics` がその向きに対応しているため。spec/mdr-v1.md の設計原則 2）。
final class ImageEncoder {

    private let context: CIContext
    /// Metal テクスチャへ直接描画するための、デバイス指定つきコンテキスト。
    let renderContext: CIContext
    let colorSpace: CGColorSpace

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        // ソフトウェアレンダラを避けて Metal 経路を使う
        context = CIContext(options: [.useSoftwareRenderer: false])
        renderContext = device.map { CIContext(mtlDevice: $0) } ?? context
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    func jpeg(from pixelBuffer: CVPixelBuffer, quality: CGFloat = 0.92) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(
                rawValue: kCGImageDestinationLossyCompressionQuality as String
            ): quality
        ]
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }
}

extension ImageEncoder {
    /// 焼き込み用に縮小した BGRA テクスチャを作る。
    ///
    /// CIContext に YCbCr→RGB と縮小をまとめて任せる。GPU 上で完結するので
    /// JPEG を経由するより速く、フル解像度を保持せずに済むのでメモリも節約できる。
    func downscaledTexture(from pixelBuffer: CVPixelBuffer,
                           width: Int,
                           device: MTLDevice) -> MTLTexture? {
        let src = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = CGFloat(width) / src.extent.width
        let scaled = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(scaled.extent.width.rounded())
        let h = Int(scaled.extent.height.rounded())

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let tex = device.makeTexture(descriptor: desc),
              let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer()
        else { return nil }

        renderContext.render(scaled, to: tex, commandBuffer: cb,
                             bounds: scaled.extent, colorSpace: colorSpace)
        cb.commit()
        cb.waitUntilCompleted()
        return tex
    }
}
