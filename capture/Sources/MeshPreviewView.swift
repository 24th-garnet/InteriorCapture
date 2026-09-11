import ARKit
import SceneKit
import SwiftUI
import simd

/// 撮影中に右下へ出す、頂点カラーのプレビュー。
///
/// **目的は「まだ撮れていない所」を撮影者に直感的に伝えること。**
/// そのために**撮影者と同じ位置・同じ向き・同じ画角**で描く。カメラ映像に
/// 重なる位置関係で未撮影が見えるので、どこへ向ければよいかが即分かる。
///
/// 俯瞰は一度試して却下した。撮り残しの分布は分かるが、**いま自分がどこを
/// 向いているかと結び付かない**ので、体を動かす指示にならなかった。
///
/// 見せ方で踏んだ問題:
///
/// - **未着色が灰色だと一様な塊に見える。** 撮り始めは大半が未着色で、
///   灰色の壁と区別が付かない。未着色は**赤紫**で描く
/// - 陰影を足さない（`lightingModel = .constant`）。撮り残しと紛らわしい
///
/// 更新の分担:
///
/// - **視点は毎フレーム**（`CADisplayLink`）。`@Published` にすると毎フレーム
///   SwiftUI 全体が再描画されるので、ここから直接引きに行く
/// - **色は 2 秒ごと**（`CaptureSession` のタイマー）。焼き直しに 0.26 秒かかる
struct MeshPreviewView: UIViewRepresentable {

    /// 姿勢を引きに行く先。毎フレーム読むので参照で持つ。
    let session: CaptureSession
    let preview: CaptureSession.MeshPreview?

    /// 未着色の色。彩度の高い色にして、実際の内装の色と混ざらないようにする。
    static let unfilledColor = SIMD3<Float>(0.85, 0.05, 0.45)
    /// 近すぎる面を描かない距離。手元の壁で画面が埋まるのを防ぐ。
    static let zNear: Float = 0.05
    static let zFar: Float = 40

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        view.allowsCameraControl = false
        view.antialiasingMode = .none        // A12Z の負荷を足さない
        view.rendersContinuously = true      // 視点が毎フレーム動く
        view.preferredFramesPerSecond = 20

        // 投影は毎フレーム `ARCamera` から作るので、ここでは器だけ用意する。
        let node = SCNNode()
        node.camera = SCNCamera()
        view.scene?.rootNode.addChildNode(node)
        view.pointOfView = node

        context.coordinator.cameraNode = node
        context.coordinator.session = session
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.session = session
        guard let p = preview, !p.vertices.isEmpty, p.indices.count >= 3 else { return }
        guard context.coordinator.version != p.elapsed else { return }
        context.coordinator.version = p.elapsed

        guard let geo = MeshPreviewView.geometry(p) else { return }
        context.coordinator.meshNode?.removeFromParentNode()
        let node = SCNNode(geometry: geo)
        view.scene?.rootNode.addChildNode(node)
        context.coordinator.meshNode = node
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// 画面の向き。`UIDevice.orientation` は伏せ置きなどで当てにならないので、
    /// ウィンドウシーンの値を使う。取れなければ縦とみなす。
    static func interfaceOrientation(of view: UIView) -> UIInterfaceOrientation {
        (view.window?.windowScene?.interfaceOrientation) ?? .portrait
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 視点の追従。`CADisplayLink` で毎フレーム姿勢を読み、カメラに移す。
    final class Coordinator {
        var meshNode: SCNNode?
        var cameraNode: SCNNode?
        weak var session: CaptureSession?
        /// 同じ内容で作り直さないための印。`elapsed` は毎回変わる。
        var version: TimeInterval = -1
        weak var view: SCNView?
        private var link: CADisplayLink?

        func start() {
            guard link == nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFramesPerSecond = 20
            l.add(to: .main, forMode: .common)
            link = l
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick() {
            guard let arCamera = session?.currentARCamera,
                  let node = cameraNode, let view = view else { return }
            let size = view.bounds.size
            guard size.width > 1, size.height > 1 else { return }

            // **画面の向きを渡すのが要点。** `camera.transform` をそのまま使うと
            // ARKit の画像が横向き基準なので、縦持ちで 90 度回る。
            let orientation = MeshPreviewView.interfaceOrientation(of: view)
            node.simdTransform = simd_inverse(arCamera.viewMatrix(for: orientation))
            // 画角も同じ理由で `projectionMatrix` から取る。縦横を取り違えると
            // 視野が狭く見える。ビューポートの大きさも渡すこと。
            node.camera?.projectionTransform = SCNMatrix4(
                arCamera.projectionMatrix(for: orientation, viewportSize: size,
                                          zNear: CGFloat(MeshPreviewView.zNear),
                                          zFar: CGFloat(MeshPreviewView.zFar)))
        }
    }

    /// 頂点カラー付きのジオメトリを組む。
    ///
    /// **一人称なので天井は切らない。** 上を向けば天井が見えるのが正しく、
    /// 切ると「そこは撮らなくてよい」と誤解させる。
    static func geometry(_ p: CaptureSession.MeshPreview) -> SCNGeometry? {
        guard p.indices.count >= 3 else { return nil }

        let positionData = p.vertices.withUnsafeBufferPointer { Data(buffer: $0) }
        let positions = SCNGeometrySource(
            data: positionData, semantic: .vertex,
            vectorCount: p.vertices.count, usesFloatComponents: true,
            componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            // **`SIMD3<Float>` は 16 バイトにパディングされる。**
            // stride を渡せるので詰め直しは不要だが、12 を渡すと全部ずれる。
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)

        // 色は 0..1 の float3。**未着色は撮り残しとして赤紫で描く。**
        var rgb = [Float](); rgb.reserveCapacity(p.colors.count * 3)
        for (i, c) in p.colors.enumerated() {
            if i < p.filled.count, !p.filled[i] {
                rgb.append(unfilledColor.x); rgb.append(unfilledColor.y); rgb.append(unfilledColor.z)
            } else {
                rgb.append(Float(c.x) / 255); rgb.append(Float(c.y) / 255); rgb.append(Float(c.z) / 255)
            }
        }
        let colorData = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
        let colors = SCNGeometrySource(
            data: colorData, semantic: .color,
            vectorCount: p.colors.count, usesFloatComponents: true,
            componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)

        let indexData = p.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .triangles,
            primitiveCount: p.indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size)

        let geo = SCNGeometry(sources: [positions, colors], elements: [element])
        let mat = SCNMaterial()
        // 焼き込んだ色をそのまま出す。陰影を足すと撮り残しと紛らわしい。
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        geo.materials = [mat]
        return geo
    }
}
