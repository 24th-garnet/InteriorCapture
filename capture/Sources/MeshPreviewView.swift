import SceneKit
import SwiftUI
import simd

/// 撮影中に右下へ出す、頂点カラーのプレビュー。
///
/// **撮り残しをその場で見つけるためのもの。** 最終品には使わない
/// （色の解像度がメッシュの辺の長さ＝約 2cm に落ちるため）。
///
/// 真上からの俯瞰にしている。三人称追従より**どこを撮っていないかが分かる**。
struct MeshPreviewView: UIViewRepresentable {

    let preview: CaptureSession.MeshPreview?

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        view.allowsCameraControl = false
        view.antialiasingMode = .none        // A12Z の負荷を足さない
        view.rendersContinuously = false     // 差し替えたときだけ描く
        view.preferredFramesPerSecond = 10

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.zNear = 0.01
        camera.zFar = 100
        let node = SCNNode()
        node.camera = camera
        // 真上から見下ろす。+Z が画面下になる向きで、間取り図と揃う。
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        view.scene?.rootNode.addChildNode(node)
        context.coordinator.cameraNode = node
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let p = preview, !p.vertices.isEmpty, p.indices.count >= 3 else { return }
        guard context.coordinator.version != p.elapsed else { return }
        context.coordinator.version = p.elapsed

        context.coordinator.meshNode?.removeFromParentNode()
        let node = SCNNode(geometry: MeshPreviewView.geometry(p))
        view.scene?.rootNode.addChildNode(node)
        context.coordinator.meshNode = node

        // 見えている範囲に合わせて俯瞰の高さと倍率を決める
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in p.vertices { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        let center = (lo + hi) / 2
        let span = max(max(hi.x - lo.x, hi.z - lo.z), 0.5)
        context.coordinator.cameraNode?.position =
            SCNVector3(center.x, hi.y + 2, center.z)
        context.coordinator.cameraNode?.camera?.orthographicScale = Double(span) * 0.6
        view.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var meshNode: SCNNode?
        var cameraNode: SCNNode?
        /// 同じ内容で作り直さないための印。`elapsed` は毎回変わる。
        var version: TimeInterval = -1
    }

    /// 頂点カラー付きのジオメトリを組む。
    ///
    /// **`SIMD3<Float>` は 16 バイトにパディングされる。** `SCNGeometrySource`
    /// には stride を渡せるので詰め直しは要らないが、渡す値を間違えると
    /// 頂点が 1 つおきにずれる（GLB で同じ誤りを踏んだ）。
    private static func geometry(_ p: CaptureSession.MeshPreview) -> SCNGeometry {
        let positionData = p.vertices.withUnsafeBufferPointer { Data(buffer: $0) }
        let positions = SCNGeometrySource(
            data: positionData, semantic: .vertex,
            vectorCount: p.vertices.count, usesFloatComponents: true,
            componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)

        // 色は 0..1 の float3 に直す。SceneKit は uchar の色を受け付けない。
        var rgb = [Float](); rgb.reserveCapacity(p.colors.count * 3)
        for c in p.colors {
            rgb.append(Float(c.x) / 255); rgb.append(Float(c.y) / 255); rgb.append(Float(c.z) / 255)
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
        // 焼き込んだ色をそのまま出す。陰影を足すと撮り残しの黒と紛らわしい。
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        geo.materials = [mat]
        return geo
    }
}
