import Foundation
import Metal
import MetalKit
import MetalSplatter
import SplatIO
import simd

/// MetalSplatter を使って station 視点から 3DGS を描画する。
///
/// - Important: クラス全体を `@MainActor` にしてはいけない。
///   PLY の解析（50万 splat で 112MB）がメインスレッドを占有し、
///   ウィンドウが一切描画されなくなる。読み込みは背景で行い、
///   UI に触るところだけ MainActor に渡す。
final class TourRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var splatRenderer: SplatRenderer?
    private let camera: TourCamera

    private var lastFrameTime = CFAbsoluteTimeGetCurrent()
    var onStatus: ((String) -> Void)?

    /// 視野角。室内は狭いので広めに取らないと閉塞感が出る。
    private let fovY: Float = 65 * .pi / 180

    init(device: MTLDevice, camera: TourCamera) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw TourError.metalUnavailable
        }
        self.commandQueue = queue
        self.camera = camera
        super.init()
    }

    func load(splatURL: URL) async throws {
        let renderer = try SplatRenderer(device: device,
                                         colorFormat: .bgra8Unorm,
                                         depthFormat: .depth32Float,
                                         sampleCount: 1,
                                         maxViewCount: 1,
                                         maxSimultaneousRenders: 3)

        let reader = try AutodetectSceneReader(splatURL)
        var points: [SplatPoint] = []
        var lastReport = 0
        for try await batch in try await reader.read() {
            points.append(contentsOf: batch)
            // 進捗はバッチごとに出さない。50万 splat では MainActor への
            // Task が大量に積まれて、それ自体が読み込みより重くなる。
            if points.count - lastReport > 50_000 {
                lastReport = points.count
                report("読み込み中 \(points.count / 1000)k splat")
            }
        }
        guard !points.isEmpty else { throw TourError.emptyScene }

        report("GPU へ転送中 \(points.count / 1000)k splat")
        let chunk = try SplatChunk(device: device, from: points)
        _ = await renderer.addChunk(chunk)
        splatRenderer = renderer
        report("\(points.count / 1000)k splat")
    }

    private func report(_ text: String) {
        let handler = onStatus
        Task { @MainActor in handler?(text) }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        camera.update(deltaTime: Float(now - lastFrameTime))
        lastFrameTime = now

        guard let renderer = splatRenderer,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { return }

        let aspect = Float(size.width / size.height)
        let projection = Self.perspective(fovY: fovY, aspect: aspect, near: 0.05, far: 60)

        let viewport = SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(originX: 0, originY: 0,
                                  width: size.width, height: size.height,
                                  znear: 0, zfar: 1),
            projectionMatrix: projection,
            viewMatrix: camera.viewMatrix,
            screenSize: SIMD2(Int(size.width), Int(size.height))
        )

        do {
            _ = try renderer.render(viewports: [viewport],
                                    colorTexture: drawable.texture,
                                    colorStoreAction: .store,
                                    depthTexture: descriptor.depthAttachment.texture,
                                    rasterizationRateMap: nil,
                                    renderTargetArrayLength: 1,
                                    to: commandBuffer)
        } catch {
            onStatus?("描画エラー: \(error.localizedDescription)")
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// 右手系・深度 [0,1] の透視投影。
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)
        )
    }
}

enum TourError: LocalizedError {
    case metalUnavailable
    case emptyScene

    var errorDescription: String? {
        switch self {
        case .metalUnavailable: return "Metal デバイスを初期化できません"
        case .emptyScene: return "splat が空です"
        }
    }
}
