import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// テクスチャ付きメッシュを GLB で書き出す。
///
/// Scaniverse の出力と同じ構成（POSITION + TEXCOORD_0 + JPEG テクスチャ 1 枚）。
/// Quick Look・Blender・Three.js でそのまま開ける。
enum GLBWriter {

    enum WriteError: LocalizedError {
        case jpegEncodingFailed
        var errorDescription: String? { "テクスチャの JPEG 化に失敗しました" }
    }

    static func write(
        vertices: [SIMD3<Float>],
        uvs: [SIMD2<Float>],
        indices: [UInt32],
        textureRGBA: Data,
        atlasSize: Int,
        to url: URL,
        jpegQuality: Float = 0.9
    ) throws {
        var blob = Data()

        func append(_ bytes: Data) -> (offset: Int, length: Int) {
            let offset = blob.count
            blob.append(bytes)
            while blob.count % 4 != 0 { blob.append(0) }
            return (offset, bytes.count)
        }

        let posRange = append(vertices.withUnsafeBufferPointer { Data(buffer: $0) })
        // glTF の UV 原点は画像左上。アトラスも v=0 を上端としてラスタライズしているので
        // 上下反転は不要。反転するとチャートが散在するアトラス上の別位置を参照し、
        // 「ランダムなパッチワーク」に見える（Mac 側実装で実際に踏んだ）。
        let uvRange = append(uvs.withUnsafeBufferPointer { Data(buffer: $0) })
        let idxRange = append(indices.withUnsafeBufferPointer { Data(buffer: $0) })
        guard let jpeg = encodeJPEG(rgba: textureRGBA, size: atlasSize, quality: jpegQuality) else {
            throw WriteError.jpegEncodingFailed
        }
        let texRange = append(jpeg)

        var minV = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxV = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in vertices { minV = simd_min(minV, v); maxV = simd_max(maxV, v) }

        let gltf: [String: Any] = [
            "asset": ["version": "2.0", "generator": "madoriba-capture"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [[
                "attributes": ["POSITION": 0, "TEXCOORD_0": 1],
                "indices": 2, "material": 0,
            ]]]],
            "materials": [[
                "pbrMetallicRoughness": [
                    "baseColorTexture": ["index": 0],
                    "metallicFactor": 0.0, "roughnessFactor": 0.9,
                ],
                "doubleSided": true,
            ]],
            "textures": [["source": 0, "sampler": 0]],
            "samplers": [["magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071]],
            "images": [["bufferView": 3, "mimeType": "image/jpeg"]],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": vertices.count, "type": "VEC3",
                 "min": [minV.x, minV.y, minV.z], "max": [maxV.x, maxV.y, maxV.z]],
                ["bufferView": 1, "componentType": 5126, "count": uvs.count, "type": "VEC2"],
                ["bufferView": 2, "componentType": 5125, "count": indices.count, "type": "SCALAR"],
            ],
            "bufferViews": [
                ["buffer": 0, "byteOffset": posRange.offset, "byteLength": posRange.length, "target": 34962],
                ["buffer": 0, "byteOffset": uvRange.offset, "byteLength": uvRange.length, "target": 34962],
                ["buffer": 0, "byteOffset": idxRange.offset, "byteLength": idxRange.length, "target": 34963],
                ["buffer": 0, "byteOffset": texRange.offset, "byteLength": texRange.length],
            ],
            "buffers": [["byteLength": blob.count]],
        ]

        var json = try JSONSerialization.data(withJSONObject: gltf)
        while json.count % 4 != 0 { json.append(0x20) }   // 空白で 4 バイト境界に揃える

        var out = Data()
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        out.append(u32(0x4674_6C67))                       // "glTF"
        out.append(u32(2))
        out.append(u32(UInt32(12 + 8 + json.count + 8 + blob.count)))
        out.append(u32(UInt32(json.count))); out.append(u32(0x4E4F_534A))  // JSON
        out.append(json)
        out.append(u32(UInt32(blob.count))); out.append(u32(0x0046_4942))  // BIN
        out.append(blob)

        try out.write(to: url)
    }

    /// 未着色テクセル（alpha=0）は黒として書く。dilate 済みなので実際にはほぼ残らない。
    private static func encodeJPEG(rgba: Data, size: Int, quality: Float) -> Data? {
        guard let provider = CGDataProvider(data: rgba as CFData),
              let cgImage = CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
