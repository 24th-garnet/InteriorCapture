import ARKit
import CoreVideo
import Foundation
import simd

/// MDR v1 バンドルを書き出す。仕様: spec/mdr-v1.md
///
/// 設計原則は「**ARKit の生値をそのまま保存する**」。座標変換・単位変換・向きの正規化を
/// ここで一切行わない。変換は recon 側に集約する。capture 側で変換すると、
/// 変換にバグが見つかったときに再撮影が必要になってしまう。
final class MDRWriter {

    enum WriterError: Error, LocalizedError {
        case depthUnavailable
        case compressionFailed(String)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .depthUnavailable: return "深度データがありません"
            case .compressionFailed(let what): return "圧縮に失敗しました: \(what)"
            case .encodingFailed: return "JPEG エンコードに失敗しました"
            }
        }
    }

    let bundleURL: URL
    private let framesURL: URL
    private let encoder = ImageEncoder()

    private var poseLines: [String] = []
    private(set) var frameCount = 0
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private(set) var depthSize: (width: Int, height: Int) = (0, 0)

    init(root: URL, sessionID: String) throws {
        bundleURL = root.appendingPathComponent("room-\(sessionID).mdr", isDirectory: true)
        framesURL = bundleURL.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
    }

    // MARK: - フレーム

    func write(frame: ARFrame, metrics: KeyframeSelector.Metrics) throws {
        guard let depth = frame.sceneDepth else { throw WriterError.depthUnavailable }

        let index = frameCount
        let name = String(format: "%06d", index)

        guard let jpeg = encoder.jpeg(from: frame.capturedImage) else {
            throw WriterError.encodingFailed
        }
        try jpeg.write(to: framesURL.appendingPathComponent("\(name).jpg"))

        let depthRaw = Self.float16Data(from: depth.depthMap)
        depthSize = (CVPixelBufferGetWidth(depth.depthMap), CVPixelBufferGetHeight(depth.depthMap))
        guard let depthZ = Deflate.compress(depthRaw) else {
            throw WriterError.compressionFailed("depth")
        }
        try depthZ.write(to: framesURL.appendingPathComponent("\(name).depth.zz"))

        if let confidence = depth.confidenceMap {
            let confRaw = Self.uint8Data(from: confidence)
            guard let confZ = Deflate.compress(confRaw) else {
                throw WriterError.compressionFailed("confidence")
            }
            try confZ.write(to: framesURL.appendingPathComponent("\(name).conf.zz"))
        }

        poseLines.append(Self.poseLine(index: index, frame: frame, metrics: metrics))

        if firstTimestamp == nil { firstTimestamp = frame.timestamp }
        lastTimestamp = frame.timestamp
        frameCount += 1
    }

    private static func poseLine(
        index: Int, frame: ARFrame, metrics: KeyframeSelector.Metrics
    ) -> String {
        let camera = frame.camera

        // transform は列優先で書く（simd_float4x4 のメモリ並びそのまま）。
        // recon 側は reshape(4,4).T で読む。spec/mdr-v1.md 参照。
        let m = camera.transform
        let transform: [Float] = [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
        ]

        // intrinsics は fx/fy/cx/cy に分解して書く。float[9] にすると
        // 行優先/列優先の取り違えが起きても計算が通ってしまい発見が遅れる。
        let k = camera.intrinsics
        var object: [String: Any] = [
            "i": index,
            "t": frame.timestamp,
            "transform": transform.map { Double($0) },
            "intrinsics": [
                "fx": Double(k.columns.0.x),
                "fy": Double(k.columns.1.y),
                "cx": Double(k.columns.2.x),
                "cy": Double(k.columns.2.y),
            ],
            "tracking": trackingName(camera.trackingState),
            "conf_high_ratio": metrics.confidenceHighRatio,
            "sharpness": metrics.sharpness,
        ]

        if #available(iOS 16.0, *) {
            let exif = frame.exifData
            var e: [String: Any] = [:]
            if let v = exif["ExposureTime"] as? Double { e["exposure"] = v }
            if let v = exif["ISOSpeedRatings"] as? [Double], let first = v.first { e["iso"] = first }
            if let v = exif["ISOSpeedRatings"] as? Double { e["iso"] = v }
            if let v = exif["BrightnessValue"] as? Double { e["brightness"] = v }
            if !e.isEmpty { object["exif"] = e }
        }

        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func trackingName(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .limited: return "limited"
        case .notAvailable: return "notAvailable"
        }
    }

    // MARK: - ピクセルバッファの取り出し

    /// 深度を float16 の raw バイト列にする。
    ///
    /// LiDAR の実用レンジは 5m までで、float16 の 5m 付近の刻みは約 2.4mm。
    /// LiDAR 自体の精度がこれより粗いので情報を失わずに容量が半分になる。
    static func float16Data(from buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }

        var out = [Float16](repeating: 0, count: width * height)
        for row in 0..<height {
            let src = base.advanced(by: row * rowBytes).assumingMemoryBound(to: Float32.self)
            for col in 0..<width {
                out[row * width + col] = Float16(src[col])
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 行パディングを取り除いた uint8 の raw バイト列。
    static func uint8Data(from buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }

        var out = Data(capacity: width * height)
        for row in 0..<height {
            let src = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
            out.append(UnsafeBufferPointer(start: src, count: width))
        }
        return out
    }

    // MARK: - 完了処理

    func finish(probe: DeviceProbe.Report, format: ARConfiguration.VideoFormat, gravity: SIMD3<Float>?) throws {
        try poseLines.joined(separator: "\n").appending("\n")
            .write(to: bundleURL.appendingPathComponent("poses.jsonl"), atomically: true, encoding: .utf8)

        var manifest: [String: Any] = [
            "schema_version": "mdr-1",
            "session_id": bundleURL.deletingPathExtension().lastPathComponent,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "device": [
                "model": probe.model,
                "os": probe.os,
                "has_lidar": probe.hasLiDAR,
            ],
            // 想定値ではなく実際に使われた形式を書く
            "video": [
                "width": Int(format.imageResolution.width),
                "height": Int(format.imageResolution.height),
                "fps": format.framesPerSecond,
            ],
            "depth": [
                "width": depthSize.width,
                "height": depthSize.height,
                "format": "float16",
                "unit": "meter",
            ],
            "world_alignment": "gravity",
            "frame_count": frameCount,
        ]
        if let g = gravity {
            manifest["gravity"] = [Double(g.x), Double(g.y), Double(g.z)]
        }
        if let first = firstTimestamp, let last = lastTimestamp {
            manifest["duration_sec"] = last - first
        }

        let data = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: bundleURL.appendingPathComponent("manifest.json"))
    }

    /// ARMeshAnchor 群を binary PLY で書く（Tier 1: 間取り・寸法・dollhouse 用）。
    /// 3DGS の学習には使わない。
    func writeMesh(anchors: [ARMeshAnchor]) throws {
        var vertices: [SIMD3<Float>] = []
        var faces: [(Int32, Int32, Int32)] = []

        for anchor in anchors {
            let geometry = anchor.geometry
            let base = Int32(vertices.count)
            let transform = anchor.transform

            let vertexBuffer = geometry.vertices
            for i in 0..<vertexBuffer.count {
                let offset = vertexBuffer.offset + vertexBuffer.stride * i
                let local = vertexBuffer.buffer.contents().advanced(by: offset)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                vertices.append(SIMD3(world.x, world.y, world.z))
            }

            let faceBuffer = geometry.faces
            let indices = faceBuffer.buffer.contents().assumingMemoryBound(to: Int32.self)
            for f in 0..<faceBuffer.count {
                let o = f * faceBuffer.indexCountPerPrimitive
                faces.append((base + indices[o], base + indices[o + 1], base + indices[o + 2]))
            }
        }

        var out = Data()
        let header = """
        ply
        format binary_little_endian 1.0
        element vertex \(vertices.count)
        property float x
        property float y
        property float z
        element face \(faces.count)
        property list uchar int vertex_indices
        end_header

        """
        out.append(header.data(using: .ascii)!)
        for v in vertices {
            var x = v.x, y = v.y, z = v.z
            out.append(Data(bytes: &x, count: 4))
            out.append(Data(bytes: &y, count: 4))
            out.append(Data(bytes: &z, count: 4))
        }
        for f in faces {
            var count: UInt8 = 3
            var a = f.0, b = f.1, c = f.2
            out.append(Data(bytes: &count, count: 1))
            out.append(Data(bytes: &a, count: 4))
            out.append(Data(bytes: &b, count: 4))
            out.append(Data(bytes: &c, count: 4))
        }
        try out.write(to: bundleURL.appendingPathComponent("mesh.ply"))
    }
}
