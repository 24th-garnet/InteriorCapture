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
        /// 段階ごとの所要秒。
        ///
        /// **どこを削るべきかは実機で測らないと決まらない。** Mac 移植版では
        /// UV 展開 35% / 投影 64% だったが、iPad は投影を Metal で回すぶん
        /// 比率が違うはず。移植版の数字で iOS の設計を決めてはいけない。
        let timings: Timings
        /// 展開の内訳。原因の切り分け用。
        let unwrapDetail: UnwrapDetail
    }

    /// 展開の内訳。**端末で段階を知るため。** Mac では ComputeCharts が
    /// 支配的だが、端末は同じ入力の変化で 12.8 倍になった。計算量か
    /// メモリ逼迫かを切り分ける。
    struct UnwrapDetail {
        var addMesh: Double = 0
        var computeCharts: Double = 0
        var packCharts: Double = 0
        var buildOutput: Double = 0
        var charts: Int = 0
        var hardwareConcurrency: Int = 0
        var availableMemoryBefore: UInt64 = 0
        var availableMemoryAfter: UInt64 = 0
        var availableMemoryMin: UInt64 = 0
    }

    struct Timings {
        /// **壁時計。アプリが停止されている間も進む。**
        ///
        /// バックグラウンドに回るとプロセスは約 30 秒で停止され、その間
        /// 計算は進まないが壁時計は進む。`cpu` と比べれば分かる。
        var unwrap: TimeInterval = 0
        var rasterize: TimeInterval = 0
        var project: TimeInterval = 0
        var resolve: TimeInterval = 0
        /// 焼き込み全体で実際に使った CPU 時間（全スレッド合計）。
        ///
        /// **壁時計と比べるためにある。** xatlas は複数スレッドを使うので
        /// 通常は壁時計より大きくなる。**壁時計を大きく下回っていれば、
        /// その差はアプリが停止されていた時間**（アプリを離れた）。
        var cpu: TimeInterval = 0

        var summary: String {
            String(format: "展開 %.1f / ラスタ %.1f / 投影 %.1f / 解決 %.1f / CPU %.1f",
                   unwrap, rasterize, project, resolve, cpu)
        }
    }

    /// プロセスが使った CPU 時間（ユーザ + システム、全スレッド合計）。
    ///
    /// **停止されている間は進まない。** 壁時計との差でアプリの離脱を検出する。
    static func processCPUSeconds() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let u = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let s = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return u + s
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
    fileprivate let bakeVertexPipeline: MTLComputePipelineState
    fileprivate let resolveVertexPipeline: MTLComputePipelineState

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
        bakeVertexPipeline = try pipeline("bakeFrameVertex")
        resolveVertexPipeline = try pipeline("resolveVertexColors")
    }

    /// 頂点カラーの焼き込み結果。
    struct VertexColorResult {
        let vertices: [SIMD3<Float>]
        let indices: [UInt32]
        /// 頂点ごとの RGB（0..255）。
        let colors: [SIMD3<UInt8>]
        /// 色が付いたか。**撮り残しをプレビューで見せるために要る。**
        /// 付かなかった頂点の `colors` は灰色なので、色だけでは区別できない。
        let filled: [Bool]
        /// どのフレームからも見えなかった頂点の割合。
        let unfilledRatio: Float
        let elapsed: TimeInterval
        let cpuSec: TimeInterval
    }

    /// **UV 展開を省いて頂点に色を焼く。**
    ///
    /// 展開（xatlas の ComputeCharts）はこの端末で焼き込み時間の 97% を占める
    /// （実測 55 秒のうち 54.5 秒）。色を頂点に持たせればアトラスが要らなくなり、
    /// 投影だけで済む。代償は色の解像度がメッシュの辺の長さ（実測で約 2cm）に
    /// 落ちること。テクスチャ版は 4.7mm/テクセルだった。
    ///
    /// アトラス版と違い**未着色を近傍から埋められない**（近傍の概念がない）。
    /// 見えなかった頂点は灰色になる。
    func bakeVertexColors(
        meshVertices: [SIMD3<Float>],
        meshIndices: [UInt32],
        frames: [BakedFrame],
        viewExponent: Float = 8.0,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> VertexColorResult {
        let start = CFAbsoluteTimeGetCurrent()
        let cpuStart = OnDeviceBaker.processCPUSeconds()
        let count = meshVertices.count
        guard count > 0, meshIndices.count >= 3 else { throw BakeError.unwrapFailed }

        // 頂点法線。面法線を面積重みで足す（大きい面の向きを尊重する）。
        var normals = [SIMD3<Float>](repeating: .zero, count: count)
        for t in stride(from: 0, to: meshIndices.count - 2, by: 3) {
            let a = Int(meshIndices[t]), b = Int(meshIndices[t + 1]), c = Int(meshIndices[t + 2])
            let n = simd_cross(meshVertices[b] - meshVertices[a],
                               meshVertices[c] - meshVertices[a])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        for i in 0..<count {
            let l = simd_length(normals[i])
            normals[i] = l > 1e-12 ? normals[i] / l : SIMD3<Float>(0, 1, 0)
        }

        guard let posBuf = device.makeBuffer(bytes: meshVertices,
                                             length: count * MemoryLayout<SIMD3<Float>>.stride,
                                             options: .storageModeShared),
              let nrmBuf = device.makeBuffer(bytes: normals,
                                             length: count * MemoryLayout<SIMD3<Float>>.stride,
                                             options: .storageModeShared),
              let accumBuf = device.makeBuffer(length: count * 12, options: .storageModeShared),
              let weightBuf = device.makeBuffer(length: count * 4, options: .storageModeShared),
              let colBuf = device.makeBuffer(length: count * 4, options: .storageModeShared)
        else { throw BakeError.metalUnavailable }
        zero(accumBuf, length: count * 12)
        zero(weightBuf, length: count * 4)

        let sharpnessMedian = median(frames.map { $0.sharpness })
        for (n, frame) in frames.enumerated() {
            runBakeVertex(frame: frame, count: count,
                          positions: posBuf, normals: nrmBuf,
                          accum: accumBuf, weight: weightBuf,
                          viewExponent: viewExponent,
                          sharpness: max(frame.sharpness / max(sharpnessMedian, 1e-6), 0.05))
            progress?(n + 1, frames.count)
        }
        runResolveVertex(accum: accumBuf, weight: weightBuf, out: colBuf, count: count)

        let raw = colBuf.contents().assumingMemoryBound(to: UInt8.self)
        var colors = [SIMD3<UInt8>](repeating: .zero, count: count)
        var filledFlags = [Bool](repeating: false, count: count)
        var filled = 0
        for i in 0..<count {
            colors[i] = SIMD3(raw[i * 4], raw[i * 4 + 1], raw[i * 4 + 2])
            if raw[i * 4 + 3] != 0 { filledFlags[i] = true; filled += 1 }
        }
        return VertexColorResult(
            vertices: meshVertices, indices: meshIndices, colors: colors,
            filled: filledFlags,
            unfilledRatio: 1 - Float(filled) / Float(count),
            elapsed: CFAbsoluteTimeGetCurrent() - start,
            cpuSec: OnDeviceBaker.processCPUSeconds() - cpuStart)
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
        let cpuStart = OnDeviceBaker.processCPUSeconds()
        var timings = Timings()
        var mark = start
        func lap() -> TimeInterval {
            let now = CFAbsoluteTimeGetCurrent()
            defer { mark = now }
            return now - mark
        }

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

        let detail = UnwrapDetail(
            addMesh: atlas.addMeshSec,
            computeCharts: atlas.computeChartsSec,
            packCharts: atlas.packChartsSec,
            buildOutput: atlas.buildOutputSec,
            charts: Int(atlas.chartCount),
            hardwareConcurrency: Int(atlas.hardwareConcurrency),
            availableMemoryBefore: atlas.availableMemoryBefore,
            availableMemoryAfter: atlas.availableMemoryAfter,
            availableMemoryMin: atlas.availableMemoryMin)

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
        timings.unwrap = lap()

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
        timings.rasterize = lap()

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
        timings.project = lap()

        // 4. 割り算して穴を埋める
        let texture = runResolveAndDilate(accum: accumBuf, weight: weightBuf, atlasSize: atlasSize)
        timings.resolve = lap()

        let w = weightBuf.contents().assumingMemoryBound(to: Float.self)
        let v = validBuf.contents().assumingMemoryBound(to: UInt8.self)
        var validCount = 0, filled = 0
        for i in 0..<texels where v[i] != 0 {
            validCount += 1
            if w[i] > 0 { filled += 1 }
        }

        timings.cpu = OnDeviceBaker.processCPUSeconds() - cpuStart
        return Result(
            vertices: vertices, uvs: uvs, indices: indices,
            texture: texture, atlasSize: atlasSize,
            unfilledRatio: validCount > 0 ? 1 - Float(filled) / Float(validCount) : 1,
            elapsed: CFAbsoluteTimeGetCurrent() - start,
            timings: timings,
            unwrapDetail: detail
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

        // チャート境界のにじみを防ぎ、投影が届かなかったテクセルを埋める。
        //
        // **回数は 10。** `maxIterations = 0` にすると展開は倍速になるが、
        // チャートの形が悪くなり、どのフレームからも投影が届かないテクセルが増える
        // （黒テクセル 3.1% -> 5.1%）。4 回では埋まりきらず黒い斑点として見える。
        // 10 回にすると 0.3% まで下がり、既定設定（3.1%）より良くなる:
        //
        //   iters=1 / 4 回   黒 3.1%   塊 2.07%
        //   iters=0 / 4 回   黒 5.1%   塊 3.14%
        //   iters=0 / 10 回  黒 0.3%   塊 0.19%
        //
        // GPU の 1 パスなので追加コストは無視できる。
        var src = a, dst = b
        for _ in 0..<10 {
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

// MARK: - 頂点カラーの GPU ディスパッチ

extension OnDeviceBaker {

    fileprivate func runBakeVertex(
        frame: BakedFrame, count: Int,
        positions: MTLBuffer, normals: MTLBuffer,
        accum: MTLBuffer, weight: MTLBuffer,
        viewExponent: Float, sharpness: Float
    ) {
        // `atlasSize` を頂点数として渡す（専用 uniform を増やさない）。
        var u = BakeUniforms(
            worldToCamera: frame.worldToCamera,
            fx: frame.fx, fy: frame.fy, cx: frame.cx, cy: frame.cy,
            videoWidth: UInt32(frame.rgb.width), videoHeight: UInt32(frame.rgb.height),
            depthWidth: UInt32(frame.depth.width), depthHeight: UInt32(frame.depth.height),
            atlasSize: UInt32(count),
            depthTolerance: 0.08, minFacing: 0.15,
            viewExponent: viewExponent, sharpness: sharpness,
            confidenceMin: UInt32(ARConfidenceLevel.high.rawValue)
        )
        encode { enc in
            enc.setComputePipelineState(bakeVertexPipeline)
            enc.setTexture(frame.rgb, index: 0)
            enc.setTexture(frame.depth, index: 1)
            enc.setTexture(frame.confidence, index: 2)
            enc.setBuffer(positions, offset: 0, index: 0)
            enc.setBuffer(normals, offset: 0, index: 1)
            enc.setBuffer(accum, offset: 0, index: 2)
            enc.setBuffer(weight, offset: 0, index: 3)
            enc.setBytes(&u, length: MemoryLayout<BakeUniforms>.stride, index: 4)
            enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
    }

    fileprivate func runResolveVertex(accum: MTLBuffer, weight: MTLBuffer,
                                      out: MTLBuffer, count: Int) {
        var n = UInt32(count)
        encode { enc in
            enc.setComputePipelineState(resolveVertexPipeline)
            enc.setBuffer(accum, offset: 0, index: 0)
            enc.setBuffer(weight, offset: 0, index: 1)
            enc.setBuffer(out, offset: 0, index: 2)
            enc.setBytes(&n, length: 4, index: 3)
            enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
    }
}
