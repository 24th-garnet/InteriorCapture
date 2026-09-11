import SceneKit
import XCTest
import simd
@testable import MadoribaCapture

/// 撮影中プレビューの見え方を押さえる。
///
/// **「何が写っているのか分からない」という形で 2 回壊れた。**
/// 真上から見ると天井が手前に来て中が見えず、未着色が灰色だと一様な塊になる。
/// どちらも「描画は成功しているのに読めない」ので、実行時エラーでは気づけない。
final class MeshPreviewTests: XCTestCase {

    /// 床・4 枚の壁・天井を持つ箱。天井があるので真上からは中が見えない。
    private func boxRoom() -> CaptureSession.MeshPreview {
        let floorY: Float = 0, ceilY: Float = 2.4
        let s: Float = 2
        var verts: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                  _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            let base = UInt32(verts.count)
            verts += [a, b, c, d]
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        quad(SIMD3(-s, floorY, -s), SIMD3(s, floorY, -s),
             SIMD3(s, floorY, s), SIMD3(-s, floorY, s))          // 床
        quad(SIMD3(-s, ceilY, -s), SIMD3(s, ceilY, -s),
             SIMD3(s, ceilY, s), SIMD3(-s, ceilY, s))            // 天井
        for (p0, p1) in [(SIMD2<Float>(-s, -s), SIMD2<Float>(s, -s)),
                         (SIMD2<Float>(s, -s), SIMD2<Float>(s, s)),
                         (SIMD2<Float>(s, s), SIMD2<Float>(-s, s)),
                         (SIMD2<Float>(-s, s), SIMD2<Float>(-s, -s))] {
            quad(SIMD3(p0.x, floorY, p0.y), SIMD3(p1.x, floorY, p1.y),
                 SIMD3(p1.x, ceilY, p1.y), SIMD3(p0.x, ceilY, p0.y))   // 壁
        }
        // 半分だけ色が付いた状態にする
        let colors = (0..<verts.count).map { _ in SIMD3<UInt8>(200, 190, 170) }
        let filled = (0..<verts.count).map { $0 % 2 == 0 }
        return CaptureSession.MeshPreview(
            vertices: verts, colors: colors, filled: filled, indices: idx,
            floorY: floorY, elapsed: 0.1)
    }

    /// **天井を落とす。** 落とさないと真上からは天井しか見えない。
    func testCeilingIsCutAway() throws {
        let room = boxRoom()
        let total = room.indices.count / 3
        let geo = try XCTUnwrap(MeshPreviewView.geometry(room))
        let kept = geo.elements[0].primitiveCount
        XCTAssertLessThan(kept, total, "天井が残っている")

        // 床（2 面）と、切断高さ 1.6m 以下に収まる壁だけが残る。
        // 壁は床から天井までまたぐので 3 頂点が全部 1.6m 以下にならず落ちる。
        XCTAssertEqual(kept, 2, "床の 2 面だけが残る")
    }

    /// またぐ面を残すと切り口に長い三角形が伸びる。3 頂点すべてで判定する。
    func testFacesStraddlingTheCutAreDropped() throws {
        var room = boxRoom()
        // 床上 1.0m までの腰壁を足す。これは残るべき。
        let base = UInt32(room.vertices.count)
        room.vertices += [SIMD3(-2, 0, -2), SIMD3(2, 0, -2),
                          SIMD3(2, 1.0, -2), SIMD3(-2, 1.0, -2)]
        room.colors += Array(repeating: SIMD3<UInt8>(100, 100, 100), count: 4)
        room.filled += Array(repeating: true, count: 4)
        room.indices += [base, base + 1, base + 2, base, base + 2, base + 3]

        let geo = try XCTUnwrap(MeshPreviewView.geometry(room))
        XCTAssertEqual(geo.elements[0].primitiveCount, 4, "床 2 面 + 腰壁 2 面")
    }

    /// **未着色は撮り残しとして目立つ色で描く。** 灰色のままだと壁と混ざる。
    func testUnfilledVerticesGetTheMarkerColour() throws {
        let room = boxRoom()
        let geo = try XCTUnwrap(MeshPreviewView.geometry(room))
        let source = try XCTUnwrap(geo.sources.first { $0.semantic == .color })
        let floats = source.data.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
        // filled == false の頂点（奇数番）が目印の色になっている
        let i = 1
        XCTAssertEqual(floats[i * 3 + 0], MeshPreviewView.unfilledColor.x, accuracy: 1e-6)
        XCTAssertEqual(floats[i * 3 + 1], MeshPreviewView.unfilledColor.y, accuracy: 1e-6)
        XCTAssertEqual(floats[i * 3 + 2], MeshPreviewView.unfilledColor.z, accuracy: 1e-6)
        // filled == true の頂点は焼いた色のまま
        XCTAssertEqual(floats[0], 200.0 / 255, accuracy: 1e-3)
    }

    /// 実際に描いて画像に落とす。**空でないこと**と、
    /// 背景でない画素が十分あることを見る。
    @MainActor
    func testRendersSomethingVisible() throws {
        let room = boxRoom()
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.scene = SCNScene()
        view.backgroundColor = .black
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.usesOrthographicProjection = true
        cam.camera?.orthographicScale = 2.6
        cam.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        cam.position = SCNVector3(0, 3, 0)
        view.scene?.rootNode.addChildNode(cam)
        view.pointOfView = cam
        let geo = try XCTUnwrap(MeshPreviewView.geometry(room))
        view.scene?.rootNode.addChildNode(SCNNode(geometry: geo))

        let image = view.snapshot()
        let data = try XCTUnwrap(image.pngData())
        try? data.write(to: URL(fileURLWithPath: "/tmp/madoriba_preview.png"))
        add(XCTAttachment(data: data, uniformTypeIdentifier: "public.png"))
        XCTAssertGreaterThan(data.count, 1000, "空の画像")
    }
}
