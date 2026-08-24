import ARKit
import Foundation
import Metal
import simd

/// iPad 上でテクスチャ付きメッシュを生成する（Tier 1 のオンデバイス実装）。
///
/// Mac 側の numpy 実装では 605 フレームで 63 秒（うち投影・合成が 53 秒）かかっていた。
/// 各テクセルの処理は独立なので Metal のコンピュートシェーダに載せる。
///
/// 3DGS はオンデバイス化しない。Scaniverse 自身が A12Z で splat を提供しておらず
/// （対応は M1 iPad Pro 以降）、M1 Max で 250 秒かかる処理を A12Z で回すのは非現実的。
@MainActor
final class OnDeviceBaker {

    struct Result {
        let vertices: [SIMD3<Float>]
        let uvs: [SIMD2<Float>]
        let indices: [UInt32]
        let texture: Data          // RGBA8, atlasSize^2
        let atlasSize: Int
        let unfilledRatio: Float
        let elapsed: TimeInterval
    }

    enum BakeError: LocalizedError {
        case metalUnavailable
        case unwrapFailed
        case multiPageAtlas
        case allocationFailed

        var errorDescription: String? {
            switch self {
            case .metalUnavailable: return "Metal を初期化できません"
            case .unwrapFailed: return "UV 展開に失敗しました"
            case .multiPageAtlas: return "アトラスが複数ページに分かれました"
            case .allocationFailed: return "GPU バッファを確保できません"
            }
        }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let rasterize: MTLComputePipelineState
    private let bakeFrame: MTLComputePipelineState
    private let resolve: MTLComputePipelineState
    private let dilate: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { throw BakeError.metalUnavailable }

        self.device = device
        self.queue = queue
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else { throw BakeError.metalUnavailable }
            return try device.makeComputePipelineState(function: fn)
        }
        rasterize = try pipeline("rasterizeAtlas")
        bakeFrame = try pipeline("bakeFrame")
        resolve = try pipeline("resolveAtlas")
        dilate = try pipeline("dilateAtlas")
    }

    /// - Parameters:
    ///   - meshVertices: ARKit world 座標の頂点
    ///   - meshIndices: 三角形インデックス
    ///   - frames: 記録済みキーフレーム（RGB / 深度 / 信頼度 / ポーズ）
    ///   - requestedAtlasSize: xatlas に渡す目安。実際の寸法はこれより大きくなりうる。
    func bake(
        meshVertices: [SIMD3<Float>],
        meshIndices: [UInt32],
        frames: [BakedFrame],
        requestedAtlasSize: Int = 2048,
        viewExponent: Float = 8.0,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> Result {
        let start = CFAbsoluteTimeGetCurrent()

        // 1. UV 展開（xatlas / C++）
        guard let atlas = meshVertices.withUnsafeBufferPointer({ vp in
            meshIndices.withUnsafeBufferPointer { ip in
                MDRXAtlas.parametrize(
                    positions: UnsafeRawPointer(vp.baseAddress!),
                    vertexCount: UInt(meshVertices.count),
                    // SIMD3<Float> は 16 バイト。12 を渡すと座標が総崩れになる。
                    stride: UInt(MemoryLayout<SIMD3<Float>>.stride),
                    indices: ip.baseAddress!,
                    indexCount: UInt(meshIndices.count),
                    resolution: UInt32(requestedAtlasSize)
                )
            }
        }) else { throw BakeError.unwrapFailed }

        // **xatlas は resolution を上限ではなく目安として扱う。**
        // 2048 を要求しても 2367x2361 のような大きさを返す（実測）。
        // 要求値でテクスチャを作ると、チャートの配置とテクセルが対応せず
        // アトラス全面がノイズになる。実際に返ってきた寸法に合わせる。
        guard atlas.atlasCount == 1 else { throw BakeError.multiPageAtlas }
        let atlasSize = max(Int(atlas.atlasWidth), Int(atlas.atlasHeight))

        let outCount = Int(atlas.vertexCount)
        var vertices = [SIMD3<Float>](repeating: .zero, count: outCount)
        var uvs = [SIMD2<Float>](repeating: .zero, count: outCount)
        for i in 0..<outCount {
            vertices[i] = meshVertices[Int(atlas.vertexMapping[i])]
            uvs[i] = SIMD2(atlas.uvs[i * 2], atlas.uvs[i * 2 + 1])
        }
        let indices: [UInt32] = Array(UnsafeBufferPointer(start: atlas.indices, count: Int(atlas.indexCount)))

        // 2. アトラスのラスタライズ（テクセル → world 座標と法線）
        let texels = atlasSize * atlasSize
        guard
            let vBuf = device.makeBuffer(bytes: vertices, length: outCount * 16),
            let uvBuf = device.makeBuffer(bytes: uvs, length: outCount * 8),
            let iBuf = device.makeBuffer(bytes: indices, length: indices.count * 4),
            let posBuf = device.makeBuffer(length: texels * 16, options: .storageModePrivate),
            let nrmBuf = device.makeBuffer(length: texels * 16, options: .storageModePrivate),
            let validBuf = device.makeBuffer(length: texels, options: .storageModeShared),
            let accumBuf = device.makeBuffer(length: texels * 12, options: .storageModePrivate),
            let weightBuf = device.makeBuffer(length: texels * 4, options: .storageModeShared)
        else { throw BakeError.allocationFailed }

        memset(validBuf.contents(), 0, texels)
        memset(weightBuf.contents(), 0, texels * 4)

        runRasterize(vBuf, uvBuf, iBuf, posBuf, nrmBuf, validBuf,
                     triangleCount: indices.count / 3, atlasSize: atlasSize)
        zero(accumBuf, length: texels * 12)

        // 3. フレームごとに投影して重み付き加算
        let sharpnessMedian = median(frames.map { $0.sharpness }) 
        for (n, frame) in frames.enumerated() {
            runBake(frame: frame, atlasSize: atlasSize,
                    positions: posBuf, normals: nrmBuf, valid: validBuf,
                    accum: accumBuf, weight: weightBuf,
                    viewExponent: viewExponent,
                    sharpness: max(frame.sharpness / max(sharpnessMedian, 1e-6), 0.05))
            progress?(n + 1, frames.count)
        }

        // 4. 割り算して穴を埋める
        let texture = runResolveAndDilate(accum: accumBuf, weight: weightBuf, atlasSize: atlasSize)

        let w = weightBuf.contents().assumingMemoryBound(to: Float.self)
        let v = validBuf.contents().assumingMemoryBound(to: UInt8.self)
        var validCount = 0, filled = 0
        for i in 0..<texels where v[i] != 0 {
            validCount += 1
            if w[i] > 0 { filled += 1 }
        }

        return Result(
            vertices: vertices, uvs: uvs, indices: indices,
            texture: texture, atlasSize: atlasSize,
            unfilledRatio: validCount > 0 ? 1 - Float(filled) / Float(validCount) : 1,
            elapsed: CFAbsoluteTimeGetCurrent() - start
        )
    }

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 1 }
        let s = values.sorted()
        return s[s.count / 2]
    }
}

/// 焼き込みに使う 1 フレーム分のデータ。
struct BakedFrame {
    let rgb: MTLTexture           // bgra8Unorm
    let depth: MTLTexture         // r32Float
    let confidence: MTLTexture    // r8Uint
    let worldToCamera: simd_float4x4
    let fx: Float, fy: Float, cx: Float, cy: Float
    let sharpness: Float
}

// MARK: - GPU ディスパッチ

private struct RasterUniforms { var atlasSize: UInt32; var triangleCount: UInt32 }

private struct BakeUniforms {
    var worldToCamera: simd_float4x4
    var fx: Float; var fy: Float; var cx: Float; var cy: Float
    var videoWidth: UInt32; var videoHeight: UInt32
    var depthWidth: UInt32; var depthHeight: UInt32
    var atlasSize: UInt32
    var depthTolerance: Float
    var minFacing: Float
    var viewExponent: Float
    var sharpness: Float
    var confidenceMin: UInt32
}

extension OnDeviceBaker {

    private func encode(_ body: (MTLComputeCommandEncoder) -> Void) {
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        body(enc)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    fileprivate func zero(_ buffer: MTLBuffer, length: Int) {
        guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        blit.fill(buffer: buffer, range: 0..<length, value: 0)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    fileprivate func runRasterize(
        _ v: MTLBuffer, _ uv: MTLBuffer, _ i: MTLBuffer,
        _ pos: MTLBuffer, _ nrm: MTLBuffer, _ valid: MTLBuffer,
        triangleCount: Int, atlasSize: Int
    ) {
        var u = RasterUniforms(atlasSize: UInt32(atlasSize), triangleCount: UInt32(triangleCount))
        encode { enc in
            enc.setComputePipelineState(rasterize)
            enc.setBuffer(v, offset: 0, index: 0)
            enc.setBuffer(uv, offset: 0, index: 1)
            enc.setBuffer(i, offset: 0, index: 2)
            enc.setBuffer(pos, offset: 0, index: 3)
            enc.setBuffer(nrm, offset: 0, index: 4)
            enc.setBuffer(valid, offset: 0, index: 5)
            enc.setBytes(&u, length: MemoryLayout<RasterUniforms>.stride, index: 6)
            let w = rasterize.maxTotalThreadsPerThreadgroup
            enc.dispatchThreads(MTLSize(width: triangleCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(w, 256), height: 1, depth: 1))
        }
    }

    fileprivate func runBake(
        frame: BakedFrame, atlasSize: Int,
        positions: MTLBuffer, normals: MTLBuffer, valid: MTLBuffer,
        accum: MTLBuffer, weight: MTLBuffer,
        viewExponent: Float, sharpness: Float
    ) {
        var u = BakeUniforms(
            worldToCamera: frame.worldToCamera,
            fx: frame.fx, fy: frame.fy, cx: frame.cx, cy: frame.cy,
            videoWidth: UInt32(frame.rgb.width), videoHeight: UInt32(frame.rgb.height),
            depthWidth: UInt32(frame.depth.width), depthHeight: UInt32(frame.depth.height),
            atlasSize: UInt32(atlasSize),
            depthTolerance: 0.08, minFacing: 0.15,
            viewExponent: viewExponent, sharpness: sharpness,
            confidenceMin: UInt32(ARConfidenceLevel.high.rawValue)
        )
        encode { enc in
            enc.setComputePipelineState(bakeFrame)
            enc.setTexture(frame.rgb, index: 0)
            enc.setTexture(frame.depth, index: 1)
            enc.setTexture(frame.confidence, index: 2)
            enc.setBuffer(positions, offset: 0, index: 0)
            enc.setBuffer(normals, offset: 0, index: 1)
            enc.setBuffer(valid, offset: 0, index: 2)
            enc.setBuffer(accum, offset: 0, index: 3)
            enc.setBuffer(weight, offset: 0, index: 4)
            enc.setBytes(&u, length: MemoryLayout<BakeUniforms>.stride, index: 5)
            enc.dispatchThreads(MTLSize(width: atlasSize, height: atlasSize, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
    }

    fileprivate func runResolveAndDilate(accum: MTLBuffer, weight: MTLBuffer, atlasSize: Int) -> Data {
        let texels = atlasSize * atlasSize
        guard let a = device.makeBuffer(length: texels * 4, options: .storageModeShared),
              let b = device.makeBuffer(length: texels * 4, options: .storageModeShared)
        else { return Data() }

        var size = UInt32(atlasSize)
        encode { enc in
            enc.setComputePipelineState(resolve)
            enc.setBuffer(accum, offset: 0, index: 0)
            enc.setBuffer(weight, offset: 0, index: 1)
            enc.setBuffer(a, offset: 0, index: 2)
            enc.setBytes(&size, length: 4, index: 3)
            enc.dispatchThreads(MTLSize(width: atlasSize, height: atlasSize, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }

        // チャート境界のにじみを防ぐため数テクセル外側へ広げる
        var src = a, dst = b
        for _ in 0..<4 {
            encode { enc in
                enc.setComputePipelineState(dilate)
                enc.setBuffer(src, offset: 0, index: 0)
                enc.setBuffer(dst, offset: 0, index: 1)
                enc.setBytes(&size, length: 4, index: 2)
                enc.dispatchThreads(MTLSize(width: atlasSize, height: atlasSize, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            }
            swap(&src, &dst)
        }
        return Data(bytes: src.contents(), count: texels * 4)
    }
}
