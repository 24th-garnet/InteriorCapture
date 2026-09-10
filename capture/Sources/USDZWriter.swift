import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// テクスチャ付きメッシュを USDZ で書き出す。
///
/// **iOS / macOS の Quick Look が対応する 3D 形式は USDZ だけで、GLB は開けない。**
/// iPad 上でその場で確認するにはこちらが必要になる。
/// GLB は Blender / Three.js など外部ツール向けに併せて出す。
///
/// **ModelIO は USDZ を書き出せない**（`MDLAsset.canExportFileExtension("usdz")` は false で、
/// 対応しているのは usda / obj）。USDZ は「無圧縮 ZIP に usd とテクスチャを
/// 64 バイト境界で並べたもの」という仕様なので、usda を組み立てて自前で ZIP にまとめる。
enum USDZWriter {

    enum WriteError: LocalizedError {
        case textureWriteFailed
        var errorDescription: String? { "テクスチャの書き出しに失敗しました" }
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
        guard let jpeg = encodeJPEG(rgba: textureRGBA, size: atlasSize, quality: jpegQuality) else {
            throw WriteError.textureWriteFailed
        }
        let usda = makeUSDA(vertices: vertices, uvs: uvs, indices: indices, textureName: "albedo.jpg")
        try USDZArchive.write(entries: [("model.usda", Data(usda.utf8)), ("albedo.jpg", jpeg)], to: url)
    }

    private static func makeUSDA(
        vertices: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32], textureName: String
    ) -> String {
        var points = ""; points.reserveCapacity(vertices.count * 28)
        for v in vertices { points += "(\(v.x), \(v.y), \(v.z)), " }
        var st = ""; st.reserveCapacity(uvs.count * 20)
        // USD の st は原点が左下。アトラスは v=0 を上端としているのでここで反転する。
        for t in uvs { st += "(\(t.x), \(1 - t.y)), " }
        var idx = ""; idx.reserveCapacity(indices.count * 7)
        for i in indices { idx += "\(i), " }
        let counts = String(repeating: "3, ", count: indices.count / 3)

        return """
        #usda 1.0
        (
            defaultPrim = "Room"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "Room"
        {
            def Mesh "mesh" (
                prepend apiSchemas = ["MaterialBindingAPI"]
            )
            {
                uniform bool doubleSided = 1
                int[] faceVertexCounts = [\(counts.dropLast(2))]
                int[] faceVertexIndices = [\(idx.dropLast(2))]
                point3f[] points = [\(points.dropLast(2))]
                texCoord2f[] primvars:st = [\(st.dropLast(2))] (
                    interpolation = "vertex"
                )
                rel material:binding = </Room/mat>
            }

            def Material "mat"
            {
                token outputs:surface.connect = </Room/mat/surface.outputs:surface>

                def Shader "surface"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor.connect = </Room/mat/tex.outputs:rgb>
                    float inputs:metallic = 0
                    float inputs:roughness = 0.9
                    token outputs:surface
                }

                def Shader "reader"
                {
                    uniform token info:id = "UsdPrimvarReader_float2"
                    // varname は string。token だと usdchecker が型不一致を出す。
                    string inputs:varname = "st"
                    float2 outputs:result
                }

                def Shader "tex"
                {
                    uniform token info:id = "UsdUVTexture"
                    asset inputs:file = @\(textureName)@
                    float2 inputs:st.connect = </Room/mat/reader.outputs:result>
                    token inputs:wrapS = "clamp"
                    token inputs:wrapT = "clamp"
                    float3 outputs:rgb
                }
            }
        }
        """
    }

    private static func encodeJPEG(rgba: Data, size: Int, quality: Float) -> Data? {
        guard let provider = CGDataProvider(data: rgba as CFData),
              let cgImage = CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// USDZ の書庫。
///
/// USDZ は ZIP だが仕様上の制約がある:
///   - **無圧縮（stored）のみ**
///   - 各エントリのデータ開始位置が **64 バイト境界**に揃っていること
/// これは実行時にメモリマップして直接読むため。圧縮すると開けない。
enum USDZArchive {

    static func write(entries: [(name: String, data: Data)], to url: URL) throws {
        var out = Data()
        var central = Data()
        var offsets: [Int] = []

        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            let headerSize = 30 + nameBytes.count
            // データ開始が 64 バイト境界に来るよう extra field で詰める
            let padding = (64 - (out.count + headerSize) % 64) % 64

            offsets.append(out.count)
            out.append(u32(0x0403_4B50))          // ローカルヘッダ signature
            out.append(u16(10))                   // 展開に必要なバージョン
            out.append(u16(0))                    // フラグ
            out.append(u16(0))                    // 無圧縮 (stored)
            out.append(u16(0)); out.append(u16(0))              // 更新時刻・日付
            out.append(u32(crc32(data)))
            out.append(u32(UInt32(data.count)))   // 圧縮後サイズ
            out.append(u32(UInt32(data.count)))   // 元サイズ
            out.append(u16(UInt16(nameBytes.count)))
            out.append(u16(UInt16(padding)))      // extra field 長 = パディング
            out.append(nameBytes)
            out.append(Data(repeating: 0, count: padding))
            out.append(data)
        }

        for (i, (name, data)) in entries.enumerated() {
            let nameBytes = Data(name.utf8)
            central.append(u32(0x0201_4B50))      // セントラルディレクトリ signature
            central.append(u16(0x031E))           // 作成バージョン
            central.append(u16(10))
            central.append(u16(0)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(crc32(data)))
            central.append(u32(UInt32(data.count)))
            central.append(u32(UInt32(data.count)))
            central.append(u16(UInt16(nameBytes.count)))
            central.append(u16(0)); central.append(u16(0))       // extra / comment
            central.append(u16(0)); central.append(u16(0))       // disk / internal attr
            central.append(u32(0))                                // external attr
            central.append(u32(UInt32(offsets[i])))
            central.append(nameBytes)
        }

        let centralOffset = out.count
        out.append(central)
        out.append(u32(0x0605_4B50))              // EOCD
        out.append(u16(0)); out.append(u16(0))
        out.append(u16(UInt16(entries.count))); out.append(u16(UInt16(entries.count)))
        out.append(u32(UInt32(central.count)))
        out.append(u32(UInt32(centralOffset)))
        out.append(u16(0))

        try out.write(to: url)
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

// MARK: - 頂点カラー版
//
// **UV 展開を省いた経路の出力。** テクスチャが無いので ZIP に入れるのは
// usda 1 つだけ。色は `primvars:displayColor` を頂点補間で持たせる。
// `UsdPreviewSurface` の diffuseColor に接続はできない（primvar は
// シェーダ入力ではない）ので、**マテリアルを付けずに displayColor を使う**。
// Quick Look はこれを解釈する。

extension USDZWriter {

    static func writeVertexColors(
        vertices: [SIMD3<Float>],
        colors: [SIMD3<UInt8>],
        indices: [UInt32],
        to url: URL
    ) throws {
        precondition(vertices.count == colors.count)
        var points = ""; points.reserveCapacity(vertices.count * 28)
        for v in vertices { points += "(\(v.x), \(v.y), \(v.z)), " }
        // displayColor は 0..1 の linear。焼き込みは sRGB のバイト値なので割るだけ。
        var cols = ""; cols.reserveCapacity(colors.count * 24)
        for c in colors {
            cols += "(\(Float(c.x) / 255), \(Float(c.y) / 255), \(Float(c.z) / 255)), "
        }
        var idx = ""; idx.reserveCapacity(indices.count * 7)
        for i in indices { idx += "\(i), " }
        let counts = String(repeating: "3, ", count: indices.count / 3)

        let usda = """
        #usda 1.0
        (
            defaultPrim = "Room"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "Room"
        {
            def Mesh "mesh"
            {
                uniform bool doubleSided = 1
                int[] faceVertexCounts = [\(counts.dropLast(2))]
                int[] faceVertexIndices = [\(idx.dropLast(2))]
                point3f[] points = [\(points.dropLast(2))]
                color3f[] primvars:displayColor = [\(cols.dropLast(2))] (
                    interpolation = "vertex"
                )
            }
        }
        """
        try USDZArchive.write(entries: [("model.usda", Data(usda.utf8))], to: url)
    }
}
