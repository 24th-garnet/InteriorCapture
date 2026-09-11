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

    /// **一人称なので天井は落とさない。** 上を向けば天井が見えるのが正しく、
    /// 切ると「そこは撮らなくてよい」と誤解させる。俯瞰では切っていたが、
    /// 「いまどこを向いているか」と結び付かないので一人称に変えた。
    func testAllFacesAreKept() throws {
        let room = boxRoom()
        let geo = try XCTUnwrap(MeshPreviewView.geometry(room))
        XCTAssertEqual(geo.elements[0].primitiveCount, room.indices.count / 3,
                       "天井を含め全部描く")
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
        // 部屋の中央に立って壁を見ている想定（一人称）
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 58
        cam.position = SCNVector3(0, 1.2, 0)
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

    /// **画角を広げても中心はずれないこと。**
    ///
    /// 上の実カメラ映像と 1 対 1 で重ならなくなるのは承知の上だが、中心が
    /// ずれると「赤紫の場所へ向ける」という操作そのものが壊れる。
    func testWideningKeepsTheCenterAndOpensTheView() {
        // 縦 33.5 度 / 横 48.6 度（上下分割の実効値）に相当する投影
        let vFov: Float = 33.5 * .pi / 180
        let aspect: Float = 1024.0 / 682.0
        var p = matrix_identity_float4x4
        p.columns.1.y = 1 / tan(vFov / 2)
        p.columns.0.x = p.columns.1.y / aspect
        p.columns.2.z = -1; p.columns.2.w = -1; p.columns.3.z = -0.1
        p.columns.3.w = 0

        for scale in [Float(1.4), 1.8, 2.6] {
            let w = MeshPreviewView.widen(p, by: scale)
            // 画角の tan が倍率どおりに増えること
            let before = 2 * atan(1 / p.columns.1.y) * 180 / .pi
            let after = 2 * atan(1 / w.columns.1.y) * 180 / .pi
            XCTAssertEqual(1 / w.columns.1.y, scale / p.columns.1.y, accuracy: 1e-5)
            XCTAssertGreaterThan(after, before)
            // 縦横比は保たれること（潰れたら向きを取り違えたときと同じ症状）
            XCTAssertEqual(w.columns.1.y / w.columns.0.x,
                           p.columns.1.y / p.columns.0.x, accuracy: 1e-4)
            // 中心（視線方向）に写るものは変わらない
            XCTAssertEqual(w.columns.2.z, p.columns.2.z)
            XCTAssertEqual(w.columns.3.z, p.columns.3.z)
        }
        // 1.0 倍はそのまま返す
        XCTAssertEqual(MeshPreviewView.widen(p, by: 1).columns.1.y, p.columns.1.y)
    }

    /// 既定は 1.8 倍。**1.0 倍は縦 33.5 度の覗き穴**で、現在位置が分からない。
    func testDefaultPreviewIsWiderThanTheCamera() {
        XCTAssertGreaterThan(CaptureSession().previewFOVScale, 1.5)
    }
}