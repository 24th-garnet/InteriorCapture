import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Metal テクスチャを PNG に落として実機で中身を確認するための道具。
///
/// GPU に渡している入力が正しいかは、推測ではなく現物を見ないと分からない。
/// 焼き込み結果だけを見て原因を当てにいくと往復が増える。
enum TextureDebug {

    /// bgra8Unorm のテクスチャを PNG として書き出す。
    static func writePNG(_ texture: MTLTexture, to url: URL) {
        let w = texture.width, h = texture.height
        guard texture.pixelFormat == .bgra8Unorm else { return }

        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bgra, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        // CGImage は RGBA を期待するので並べ替える
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i*4+0] = bgra[i*4+2]
            rgba[i*4+1] = bgra[i*4+1]
            rgba[i*4+2] = bgra[i*4+0]
            rgba[i*4+3] = 255
        }

        rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// r32Float の深度テクスチャを、範囲を正規化したグレースケール PNG にする。
    static func writeDepthPNG(_ texture: MTLTexture, to url: URL) {
        let w = texture.width, h = texture.height
        guard texture.pixelFormat == .r32Float else { return }

        var depth = [Float](repeating: 0, count: w * h)
        texture.getBytes(&depth, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        let valid = depth.filter { $0.isFinite && $0 > 0 }
        let lo = valid.min() ?? 0, hi = valid.max() ?? 1
        var gray = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = depth[i].isFinite && depth[i] > 0
                ? UInt8(max(0, min(255, (depth[i] - lo) / max(hi - lo, 1e-6) * 255)))
                : 0
            gray[i*4+0] = v; gray[i*4+1] = v; gray[i*4+2] = v; gray[i*4+3] = 255
        }

        gray.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
