import CoreImage
import CoreVideo
import Foundation

/// `ARFrame.capturedImage`（420 YpCbCr 二平面）を JPEG にする。
///
/// vImage で YCbCr→BGRA を手組みするより CIContext に任せた方が短く、GPU で走る。
/// 画像は**センサ native の向きのまま**扱い、回転も EXIF Orientation の付与もしない
/// （`intrinsics` がその向きに対応しているため。spec/mdr-v1.md の設計原則 2）。
final class ImageEncoder {

    private let context: CIContext
    private let colorSpace: CGColorSpace

    init() {
        // ソフトウェアレンダラを避けて Metal 経路を使う
        context = CIContext(options: [.useSoftwareRenderer: false])
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
