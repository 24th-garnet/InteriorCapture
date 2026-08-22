import Compression
import Foundation

/// raw DEFLATE（RFC 1951、zlib ヘッダなし）で圧縮する。
///
/// zstd を使わないのは Apple の Compression フレームワークが zstd を持たないため
/// （LZFSE / LZ4 / ZLIB / LZMA のみ）。`COMPRESSION_ZLIB` は raw DEFLATE を吐くので、
/// Python 側は標準ライブラリの `zlib.decompress(data, wbits=-15)` で読める。
/// 双方とも外部依存ゼロになる。spec/mdr-v1.md 参照。
enum Deflate {

    static func compress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }

        // 非圧縮データでも溢れないよう余裕を持たせる
        let capacity = input.count + input.count / 2 + 1024
        var output = Data(count: capacity)

        let written = output.withUnsafeMutableBytes { dst -> Int in
            guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { src -> Int in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    dstBase, capacity,
                    srcBase, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }
        output.removeSubrange(written...)
        return output
    }
}
