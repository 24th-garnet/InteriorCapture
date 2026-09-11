import XCTest
import simd
@testable import MadoribaCapture

/// UV 展開は「静かに壊れる」種類の処理なので、性質を押さえておく。
///
/// 壊れ方は 3 つある。**どれも焼き上がったテクスチャを目で見るまで
/// 気づけない**（そして見ても原因が分からない）:
///
/// - UV がアトラスの外に出る → そのチャートは真っ黒になる
/// - 別の面が同じテクセルを取り合う（折り返し・チャートの重なり）
///   → 壁の色が床に現れる
/// - 歪む → 方向によってボケる
final class FastUnwrapTests: XCTestCase {

    // MARK: 試験用メッシュ

    /// XZ 平面の格子。法線は +Y で揃っている。
    func flatGrid(_ n: Int, step: Float = 0.1) -> ([SIMD3<Float>], [UInt32]) {
        var v = [SIMD3<Float>]()
        for z in 0...n {
            for x in 0...n {
                v.append(SIMD3(Float(x) * step, 0, Float(z) * step))
            }
        }
        var i = [UInt32]()
        let w = n + 1
        for z in 0..<n {
            for x in 0..<n {
                let a = UInt32(z * w + x), b = a + 1
                let c = UInt32((z + 1) * w + x), d = c + 1
                i += [a, c, b, b, c, d]
            }
        }
        return (v, i)
    }

    /// 単位立方体。6 面の法線が直交するので、まとめられてはいけない。
    func box() -> ([SIMD3<Float>], [UInt32]) {
        let v: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
            SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
        ]
        let quads = [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7],
                     [1, 5, 6, 2], [4, 5, 1, 0], [3, 2, 6, 7]]
        var i = [UInt32]()
        for q in quads {
            i += [UInt32(q[0]), UInt32(q[1]), UInt32(q[2]),
                  UInt32(q[0]), UInt32(q[2]), UInt32(q[3])]
        }
        return (v, i)
    }

    // MARK: 性質

    func testFlatSurfaceBecomesOneChart() {
        let (v, i) = flatGrid(8)
        let r = FastUnwrap.unwrap(vertices: v, indices: i, atlasSize: 256)
        // 平らな面を刻んだだけなので、分ける理由がない。
        XCTAssertEqual(r.chartCount, 1)
        XCTAssertEqual(r.indices.count, i.count)
    }

    /// **アトラスの外に出ないこと。** 出たチャートは真っ黒になる。
    func testUVsStayInsideTheAtlas() {
        let (v, i) = box()
        let r = FastUnwrap.unwrap(vertices: v, indices: i, atlasSize: 128)
        for uv in r.uvs {
            XCTAssertGreaterThanOrEqual(uv.x, 0)
            XCTAssertGreaterThanOrEqual(uv.y, 0)
            XCTAssertLessThanOrEqual(uv.x, 1)
            XCTAssertLessThanOrEqual(uv.y, 1)
        }
    }

    /// **平面は歪まないこと。** 平均平面への射影なので、平らな面では
    /// UV 上の辺長と実寸の比がどこでも同じになるはず。ここが崩れると
    /// 方向によってボケる（固定タイル案を却下した理由がこれ）。
    func testFlatSurfaceHasNoDistortion() {
        let (v, i) = flatGrid(6)
        let r = FastUnwrap.unwrap(vertices: v, indices: i, atlasSize: 256)
        var ratios = [Float]()
        for t in 0..<(r.indices.count / 3) {
            for k in 0..<3 {
                let a = Int(r.indices[t * 3 + k]), b = Int(r.indices[t * 3 + (k + 1) % 3])
                let world = simd_length(r.vertices[a] - r.vertices[b])
                let uv = simd_length(r.uvs[a] - r.uvs[b])
                if world > 1e-6 { ratios.append(uv / world) }
            }
        }
        let lo = ratios.min() ?? 0, hi = ratios.max() ?? 0
        XCTAssertGreaterThan(lo, 0)
        XCTAssertLessThan(hi / lo, 1.01, "平面で \(hi / lo) 倍の歪みが出ている")
    }

    /// **直交する面は同じテクセルを取り合ってはいけない。**
    ///
    /// チャートの重なりと、曲面を伝った折り返しの両方をここで捕まえる。
    /// 法線の向きごとに印を付けてラスタライズし、違う向きの面が同じ
    /// テクセルを主張したら失敗とする。
    func testDifferentSurfacesNeverShareATexel() {
        let (v, i) = box()
        let size = 128
        let r = FastUnwrap.unwrap(vertices: v, indices: i, atlasSize: size)
        var owner = [Int8](repeating: -1, count: size * size)

        for t in 0..<(r.indices.count / 3) {
            let i0 = Int(r.indices[t * 3 + 0]), i1 = Int(r.indices[t * 3 + 1]), i2 = Int(r.indices[t * 3 + 2])
            let n = simd_normalize(simd_cross(r.vertices[i1] - r.vertices[i0],
                                              r.vertices[i2] - r.vertices[i0]))
            // 法線を 6 方向に丸めて印にする
            let axis = [abs(n.x), abs(n.y), abs(n.z)].firstIndex(of: max(abs(n.x), max(abs(n.y), abs(n.z))))!
            let sign = [n.x, n.y, n.z][axis] > 0 ? 1 : 0
            let mark = Int8(axis * 2 + sign)

            let a = r.uvs[i0] * Float(size), b = r.uvs[i1] * Float(size), c = r.uvs[i2] * Float(size)
            let det = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
            if abs(det) < 1e-9 { continue }
            let x0 = max(0, Int(floor(min(a.x, min(b.x, c.x))))), x1 = min(size, Int(ceil(max(a.x, max(b.x, c.x)))))
            let y0 = max(0, Int(floor(min(a.y, min(b.y, c.y))))), y1 = min(size, Int(ceil(max(a.y, max(b.y, c.y)))))
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let px = Float(x) + 0.5, py = Float(y) + 0.5
                    let w0 = ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / det
                    let w1 = ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / det
                    let w2 = 1 - w0 - w1
                    if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                    let idx = y * size + x
                    if owner[idx] == -1 { owner[idx] = mark }
                    else {
                        XCTAssertEqual(owner[idx], mark,
                                       "テクセル (\(x),\(y)) を向きの違う面が取り合っている")
                    }
                }
            }
        }
        XCTAssertGreaterThan(owner.filter { $0 >= 0 }.count, 0, "何も乗っていない")
    }

    /// 解像度は上げた分だけ細かくなること。**逆転していたら詰めが壊れている。**
    func testLargerAtlasGivesFinerTexels() {
        let (v, i) = flatGrid(8)
        let small = FastUnwrap.unwrap(vertices: v, indices: i, atlasSize: 128)
        let large = FastUnwrap.unwrap(vertices: v, indices: i, atlasSize: 512)
        XCTAssertLessThan(large.mmPerTexel, small.mmPerTexel)
        // 一辺 4 倍なら 4 分の 1 に近づく（ガターのぶんだけ届かない）
        XCTAssertEqual(large.mmPerTexel, small.mmPerTexel / 4, accuracy: small.mmPerTexel / 8)
    }

    func testEmptyMeshIsNotACrash() {
        let r = FastUnwrap.unwrap(vertices: [], indices: [], atlasSize: 256)
        XCTAssertEqual(r.chartCount, 0)
        XCTAssertTrue(r.indices.isEmpty)
    }

    /// **空きメモリが乏しければアトラスを落とす。**
    /// 4096 は 956MB 要る。確保に失敗して焼き込み全体が落ちるより、
    /// 解像度を落として出すほうがよい。
    func testAtlasSizeFollowsAvailableMemory() {
        XCTAssertEqual(FastUnwrap.atlasSize(available: 4_000_000_000), 4096)
        XCTAssertEqual(FastUnwrap.atlasSize(available: 1_500_000_000), 3072)
        XCTAssertEqual(FastUnwrap.atlasSize(available: 300_000_000), 2048)
    }

    /// 実測のメッシュ規模で、展開が焼き込みの足を引っ張らないこと。
    ///
    /// **xatlas は同じ規模で 67.6 秒かかっていた。** ここが 1 秒を超えると
    /// 設計の前提が崩れるので、桁で押さえる。
    func testUnwrapIsFastAtRealisticScale() {
        let (v, i) = flatGrid(280)               // 156,800 面
        XCTAssertGreaterThan(i.count / 3, 150_000)
        let start = CFAbsoluteTimeGetCurrent()
        let r = FastUnwrap.unwrap(vertices: v, indices: i, atlasSize: 4096)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertEqual(r.chartCount, 1)
        // Mac の Debug ビルドで測るので、実機の目標（1 秒）より緩く見る。
        XCTAssertLessThan(elapsed, 20, "展開に \(elapsed) 秒かかった")
    }
}
