import XCTest
import simd
@testable import MadoribaCapture

/// 頂点カラーの書き出しを検証する。
///
/// **壊れた GLB / USDZ は撮影 1 回を無駄にする。** 実機で焼くまで気づけない
/// ので、構造をここで押さえる。過去に GLB で踏んだ誤りが 2 つある:
/// `SIMD3<Float>` の 16 バイトパディング混入（幾何が「ツノ」状に破綻）と、
/// チャンク長の不整合。どちらも読み込み時にしか出ない。
final class VertexColorWriterTests: XCTestCase {

    private let vertices: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0),
    ]
    private let colors: [SIMD3<UInt8>] = [
        SIMD3(255, 0, 0), SIMD3(0, 255, 0), SIMD3(0, 0, 255), SIMD3(128, 128, 128),
    ]
    private let indices: [UInt32] = [0, 1, 2, 1, 3, 2]

    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + name)
    }

    func testGLBStructureIsValid() throws {
        let url = tmp(".glb")
        try GLBWriter.writeVertexColors(vertices: vertices, colors: colors,
                                        indices: indices, to: url)
        let data = try Data(contentsOf: url)
        defer { try? FileManager.default.removeItem(at: url) }

        func u32(_ at: Int) -> UInt32 {
            data.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }
        }
        XCTAssertEqual(u32(0), 0x46546C67, "magic は 'glTF'")
        XCTAssertEqual(u32(4), 2, "version 2")
        XCTAssertEqual(Int(u32(8)), data.count, "全長がヘッダと一致する")

        let jsonLen = Int(u32(12))
        XCTAssertEqual(u32(16), 0x4E4F534A, "JSON チャンク")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: data.subdata(in: 20..<(20 + jsonLen))) as? [String: Any])

        // BIN チャンクの長さが宣言と合う
        let binLenOffset = 20 + jsonLen
        let binLen = Int(u32(binLenOffset))
        XCTAssertEqual(u32(binLenOffset + 4), 0x004E4942, "BIN チャンク")
        XCTAssertEqual(binLenOffset + 8 + binLen, data.count)
        let buffers = try XCTUnwrap(json["buffers"] as? [[String: Any]])
        XCTAssertEqual(buffers[0]["byteLength"] as? Int, binLen)

        // COLOR_0 が正規化 uchar4 で入っている
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        let prims = try XCTUnwrap(meshes[0]["primitives"] as? [[String: Any]])
        let attrs = try XCTUnwrap(prims[0]["attributes"] as? [String: Int])
        XCTAssertNotNil(attrs["POSITION"])
        let colorAccessor = try XCTUnwrap(attrs["COLOR_0"])
        XCTAssertNil(attrs["TEXCOORD_0"], "UV は持たない")
        XCTAssertNil(json["textures"], "テクスチャは持たない")

        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        let ca = accessors[colorAccessor]
        XCTAssertEqual(ca["componentType"] as? Int, 5121, "unsigned byte")
        XCTAssertEqual(ca["normalized"] as? Bool, true)
        XCTAssertEqual(ca["type"] as? String, "VEC4")
        XCTAssertEqual(ca["count"] as? Int, colors.count)
    }

    /// **`SIMD3<Float>` は 16 バイトにパディングされる。** 12 バイト詰めで
    /// 書けていないと 2 頂点目以降が全部ずれる。バイト列を直接読んで確かめる。
    func testPositionsArePackedTo12Bytes() throws {
        let url = tmp(".glb")
        try GLBWriter.writeVertexColors(vertices: vertices, colors: colors,
                                        indices: indices, to: url)
        let data = try Data(contentsOf: url)
        defer { try? FileManager.default.removeItem(at: url) }

        func u32(_ at: Int) -> UInt32 {
            data.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }
        }
        let jsonLen = Int(u32(12))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: data.subdata(in: 20..<(20 + jsonLen))) as? [String: Any])
        let views = try XCTUnwrap(json["bufferViews"] as? [[String: Any]])
        let posView = views[0]
        XCTAssertEqual(posView["byteLength"] as? Int, vertices.count * 12,
                       "12 バイト詰め（16 だとパディング混入）")

        let binStart = 20 + jsonLen + 8
        let off = binStart + (posView["byteOffset"] as? Int ?? 0)
        for (i, v) in vertices.enumerated() {
            for (k, expected) in [v.x, v.y, v.z].enumerated() {
                let at = off + i * 12 + k * 4
                let got = data.subdata(in: at..<(at + 4))
                    .withUnsafeBytes { $0.load(as: Float.self) }
                XCTAssertEqual(got, expected, accuracy: 1e-6,
                               "頂点 \(i) の成分 \(k)")
            }
        }
    }

    func testUSDZContainsDisplayColor() throws {
        let url = tmp(".usdz")
        try USDZWriter.writeVertexColors(vertices: vertices, colors: colors,
                                         indices: indices, to: url)
        let data = try Data(contentsOf: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // USDZ は無圧縮 ZIP。先頭がローカルファイルヘッダ。
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "ZIP ヘッダ")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("model.usda"))
        XCTAssertTrue(text.contains("primvars:displayColor"), "頂点色が入っている")
        XCTAssertTrue(text.contains("interpolation = \"vertex\""))
        XCTAssertFalse(text.contains("albedo.jpg"), "テクスチャは入らない")
        // 色が 0..1 に正規化されている（255 のバイト値がそのまま出ていない）
        XCTAssertTrue(text.contains("(1.0, 0.0, 0.0)"))
    }
}
