import Foundation
import simd

/// recon が出力する tour.json（station point とその隣接グラフ）。
///
/// 3DGS は撮影視点から離れると破綻するため、移動をこの station に制約する。
/// 「常に撮影視点の近傍しか描画しない」＝ 3DGS が最も得意な条件だけを使う。
struct Tour: Decodable {
    struct Station: Decodable, Identifiable {
        let index: Int
        let position: [Float]
        let forward: [Float]
        let sourceFrame: Int
        let neighbors: [Int]

        var id: Int { index }
        var pos: SIMD3<Float> { SIMD3(position[0], position[1], position[2]) }
        var fwd: SIMD3<Float> { SIMD3(forward[0], forward[1], forward[2]) }

        enum CodingKeys: String, CodingKey {
            case index, position, forward, neighbors
            case sourceFrame = "source_frame"
        }
    }

    let version: Int
    let floorY: Float
    let eyeHeight: Float
    let stations: [Station]

    enum CodingKeys: String, CodingKey {
        case version, stations
        case floorY = "floor_y"
        case eyeHeight = "eye_height"
    }

    static func load(from url: URL) throws -> Tour {
        try JSONDecoder().decode(Tour.self, from: Data(contentsOf: url))
    }

    /// 現在位置から見て、指定方向に最も素直に進める隣接 station。
    ///
    /// 単純に最近傍を選ぶと、後ろを向いているときに前進で後退してしまう。
    /// 進行方向との角度で重み付けし、真横より後ろは候補から外す。
    func step(from current: Int, towards direction: SIMD3<Float>) -> Int? {
        guard current >= 0, current < stations.count else { return nil }
        let here = stations[current]
        var best: (index: Int, score: Float)?

        for n in here.neighbors where n >= 0 && n < stations.count {
            var delta = stations[n].pos - here.pos
            delta.y = 0
            let dist = length(delta)
            guard dist > 1e-4 else { continue }
            let alignment = dot(normalize(delta), normalize(SIMD3(direction.x, 0, direction.z)))
            guard alignment > 0.25 else { continue }   // 真横〜後ろは選ばない
            let score = alignment / dist               // 正対していて近いほど良い
            if best == nil || score > best!.score {
                best = (n, score)
            }
        }
        return best?.index
    }
}
