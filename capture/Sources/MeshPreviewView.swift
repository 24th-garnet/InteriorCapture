import SceneKit
import SwiftUI
import simd

/// 撮影中に右下へ出す、頂点カラーのプレビュー。
///
/// **撮り残しをその場で見つけるためのもの。** 最終品には使わない
/// （色の解像度がメッシュの辺の長さ＝約 2cm に落ちるため）。
///
/// 見せ方で踏んだ問題が 2 つある。どちらも「何が写っているのか分からない」
/// という形で出た:
///
/// 1. **真上から見ると天井が手前に来て中が見えない。** ARKit のメッシュは
///    天井も含むので、俯瞰すると天井の裏側しか映らない。床から
///    `cutHeight` までを残して上を切る（ドールハウス表示）。
/// 2. **未着色が灰色なので一様な塊に見える。** 撮り始めは大半が未着色で、
///    灰色の壁と区別が付かない。未着色は**赤紫**で描いて撮り残しを目立たせる。
struct MeshPreviewView: UIViewRepresentable {

    let preview: CaptureSession.MeshPreview?

    /// 床から何 m までを残すか。立って撮る前提で、腰より上の壁は見たい。
    static let cutHeight: Float = 1.6
    /// 未着色の色。彩度の高い色にして、実際の内装の色と混ざらないようにする。
    static let unfilledColor = SIMD3<Float>(0.85, 0.05, 0.45)

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        view.allowsCameraControl = false
        view.antialiasingMode = .none        // A12Z の負荷を足さない
        view.preferredFramesPerSecond = 10

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.zNear = 0.01
        camera.zFar = 100
        let node = SCNNode()
        node.camera = camera
        // 真上から見下ろす。画面上が -Z（北側）になり、間取り図と向きが揃う。
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        view.scene?.rootNode.addChildNode(node)
        context.coordinator.cameraNode = node
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let p = preview, !p.vertices.isEmpty, p.indices.count >= 3 else { return }
        guard context.coordinator.version != p.elapsed else { return }
        context.coordinator.version = p.elapsed

        guard let geo = MeshPreviewView.geometry(p) else { return }
        context.coordinator.meshNode?.removeFromParentNode()
        let node = SCNNode(geometry: geo)
        view.scene?.rootNode.addChildNode(node)
        context.coordinator.meshNode = node

        // 残した部分に合わせて俯瞰の高さと倍率を決める
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in p.vertices where v.y <= p.floorY + MeshPreviewView.cutHeight {
            lo = simd_min(lo, v); hi = simd_max(hi, v)
        }
        guard lo.x <= hi.x else { return }
        let center = (lo + hi) / 2
        let span = max(max(hi.x - lo.x, hi.z - lo.z), 0.5)
        context.coordinator.cameraNode?.position =
            SCNVector3(center.x, p.floorY + MeshPreviewView.cutHeight + 1, center.z)
        // orthographicScale は表示高さの半分。少し余白を持たせる。
        context.coordinator.cameraNode?.camera?.orthographicScale = Double(span) * 0.62
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var meshNode: SCNNode?
        var cameraNode: SCNNode?
        /// 同じ内容で作り直さないための印。`elapsed` は毎回変わる。
        var version: TimeInterval = -1
    }

    /// 頂点カラー付きのジオメトリを組む。**床から `cutHeight` までを残す。**
    ///
    /// 面の 3 頂点すべてが範囲内のものだけを採る。1 頂点でも上なら落とす
    /// （またぐ面を残すと切り口に長い三角形が伸びて見苦しい）。
    static func geometry(_ p: CaptureSession.MeshPreview) -> SCNGeometry? {
        let ceiling = p.floorY + cutHeight
        var keep = [UInt32](); keep.reserveCapacity(p.indices.count)
        for t in stride(from: 0, to: p.indices.count - 2, by: 3) {
            let a = p.indices[t], b = p.indices[t + 1], c = p.indices[t + 2]
            if p.vertices[Int(a)].y <= ceiling,
               p.vertices[Int(b)].y <= ceiling,
               p.vertices[Int(c)].y <= ceiling {
                keep.append(a); keep.append(b); keep.append(c)
            }
        }
        guard keep.count >= 3 else { return nil }

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

        let indexData = keep.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .triangles,
            primitiveCount: keep.count / 3,
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
