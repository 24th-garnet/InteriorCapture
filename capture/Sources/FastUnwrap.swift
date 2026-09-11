import Foundation
import os
import simd

/// 反復最適化なしの UV 展開。**xatlas の ComputeCharts を置き換える。**
///
/// 端末の焼き込み 70 秒のうち **67.6 秒が ComputeCharts** だった（`bake.json` 3 件、
/// iPad8,11 / Release）。残りは AddMesh 0.04 / PackCharts 1.4 / 投影 0.8 /
/// ラスタ 0.1 / 解決 0.05 で、**合計 2.5 秒しかない**。遅いのはテクスチャだから
/// ではなく、UV を計算しているから。
///
/// xatlas は LSCM と反復最適化で「どんなメッシュでも」良いチャートを探す。
/// **室内は壁・床・天井という大きな平面の集まり**なので、法線の近い面を貪欲に
/// 広げてその平均平面へ射影すれば、反復なしでほぼ歪みのないチャートになる。
/// 実測（`room-77eab748` / 160,581 面、4096 アトラス）:
///
/// | | mm/texel | チャート | 展開 |
/// |---|---|---|---|
/// | xatlas 2203（現行） | 3.5（等方） | 4,924 | 67.6 秒 |
/// | 平面成長 4096（これ） | **2.50（等方）** | 7,597 | — |
///
/// **三角形 1 枚ずつ固定タイルに詰める案は却下した。** 詰めは自明になるが、
/// ARKit の三角形が細長いので UV へ写す段で歪みが中央 2.42 倍残り（タイルの
/// 縦横比を 1.0〜2.4 で振っても下限 2.42）、方向によるボケが出る。等方 2.50mm
/// のほうが明確に良い。
struct FastUnwrap {

    /// 展開の結果。`OnDeviceBaker` の既存のラスタライザがそのまま食える形。
    struct Result {
        /// チャートごとに複製された頂点（world 座標）。
        let vertices: [SIMD3<Float>]
        /// 0..1 に正規化した UV。
        let uvs: [SIMD2<Float>]
        let indices: [UInt32]
        let atlasSize: Int
        let chartCount: Int
        /// テクセル 1 枚が覆う実寸（mm）。**品質の比較はこの数字で行う。**
        let mmPerTexel: Float
        /// アトラスのうち実際に三角形が乗った割合。
        let fill: Float
        let timings: Timings
    }

    struct Timings {
        var normals: TimeInterval = 0
        var adjacency: TimeInterval = 0
        var grow: TimeInterval = 0
        var project: TimeInterval = 0
        var pack: TimeInterval = 0
        var emit: TimeInterval = 0

        var total: TimeInterval { normals + adjacency + grow + project + pack + emit }
    }

    /// 法線がチャートの平均からこれ以上離れた面は足さない。
    ///
    /// 実測では 20〜35 度のどれでも 2.50mm / 利用率 56% で差が出なかった
    /// （チャート数だけが 10,582 / 7,597 / 4,549 と動く）。真ん中を採る。
    static let averageToleranceDegrees: Float = 25

    /// **種の法線からの上限。** 平均法線だけで縛ると、緩く曲がった面を
    /// 伝ってチャートが際限なく回り込み、平面への射影が自分自身に折り返す
    /// （同じテクセルに別の場所が乗る）。実測で費用はゼロだった。
    static let seedToleranceDegrees: Float = 45

    /// チャートの周囲に空けるテクセル。
    ///
    /// 双線形補間だけなら 1 で足りる（隣のチャートとの間は両側ぶんで 2 空き、
    /// `dilateAtlas` が互いの縁を自分の色で埋める）。**2 にしているのは
    /// テクスチャを JPEG で書くから。** JPEG は 8x8 のブロックで変換するので、
    /// 継ぎ目をまたいだブロックが隣のチャートの色を引き込む。
    ///
    /// 費用は実測で 2.50 -> 2.56 mm/texel（2.4%）しかない。
    /// 3 にしても 2.61mm で、そこまで払う理由は見つかっていない。
    static let gutter = 2

    /// テクセルあたりのバイト数（`OnDeviceBaker` が確保する GPU バッファの合計）。
    ///
    /// world 座標 16 + 法線 16 + 累積 12 + 重み 4 + 有効 1 + 出力 4 + 膨張先 4。
    /// **4096 で約 956MB になる。** 端末の空きを見てから決めること。
    static let bytesPerTexel = 57

    /// 空きメモリに収まる最大のアトラス寸法を選ぶ。
    ///
    /// 4096 の 956MB は、このアプリがこれまで確保した中で最大。`bake.json` の
    /// 実測では焼き込み前の空きが 3.27GB あったので通るが、余裕を 2 倍見て
    /// 段階的に落とす。**アトラスを落とすと解像度が線形に悪化する**ので、
    /// 落としたことは `bake.json` に残す。
    static func atlasSize(candidates: [Int] = [4096, 3072, 2048],
                          available: UInt64 = UInt64(os_proc_available_memory())) -> Int {
        for size in candidates {
            let need = UInt64(size * size * bytesPerTexel) * 2
            if available == 0 || need < available { return size }
        }
        return candidates.last ?? 2048
    }

    /// 展開する。
    ///
    /// - Parameters:
    ///   - vertices: ARKit world 座標の頂点
    ///   - indices: 三角形インデックス
    ///   - atlasSize: アトラスの一辺（テクセル）。`atlasSize(candidates:available:)` で決める
    static func unwrap(vertices: [SIMD3<Float>], indices: [UInt32],
                       atlasSize: Int,
                       averageToleranceDegrees: Float = FastUnwrap.averageToleranceDegrees,
                       seedToleranceDegrees: Float = FastUnwrap.seedToleranceDegrees,
                       gutter: Int = FastUnwrap.gutter) -> Result {

        var timings = Timings()
        var mark = CFAbsoluteTimeGetCurrent()
        func lap() -> TimeInterval {
            let now = CFAbsoluteTimeGetCurrent()
            defer { mark = now }
            return now - mark
        }

        let faceCount = indices.count / 3
        guard faceCount > 0, atlasSize > 2 * gutter else {
            return Result(vertices: [], uvs: [], indices: [], atlasSize: atlasSize,
                          chartCount: 0, mmPerTexel: 0, fill: 0, timings: timings)
        }

        // 1. 面法線と面積
        var normals = [SIMD3<Float>](repeating: .zero, count: faceCount)
        var areas = [Float](repeating: 0, count: faceCount)
        for t in 0..<faceCount {
            let a = vertices[Int(indices[t * 3 + 0])]
            let b = vertices[Int(indices[t * 3 + 1])]
            let c = vertices[Int(indices[t * 3 + 2])]
            let n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            areas[t] = len * 0.5
            normals[t] = len > 1e-12 ? n / len : SIMD3<Float>(0, 1, 0)
        }
        timings.normals = lap()

        // 2. 面の隣接（辺を共有する面）
        //
        // 3 面以上が同じ辺を共有する（非多様体）ことは ARKit のメッシュでも
        // 起きる。`removeValue` で消しながら組むと、余った面は隣接なしとして
        // 扱われるだけで済む。
        var neighbor = [Int32](repeating: -1, count: faceCount * 3)
        var pending = [UInt64: Int32](minimumCapacity: faceCount * 2)
        for t in 0..<faceCount {
            for k in 0..<3 {
                let a = indices[t * 3 + k]
                let b = indices[t * 3 + (k + 1) % 3]
                let key = a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a))
                if let other = pending.removeValue(forKey: key) {
                    neighbor[t * 3 + k] = other / 3
                    neighbor[Int(other)] = Int32(t)
                } else {
                    pending[key] = Int32(t * 3 + k)
                }
            }
        }
        pending.removeAll()
        timings.adjacency = lap()

        // 3. 平面領域の成長
        let cosAverage = cos(averageToleranceDegrees * .pi / 180)
        let cosSeed = cos(seedToleranceDegrees * .pi / 180)
        var chartOf = [Int32](repeating: -1, count: faceCount)
        var chartFaces = [Int32](); chartFaces.reserveCapacity(faceCount)
        var chartStart = [Int](); var chartCount = [Int]()
        var chartAxis = [SIMD3<Float>]()
        var queue = [Int32](); queue.reserveCapacity(1024)

        for seed in 0..<faceCount where chartOf[seed] < 0 {
            let cid = Int32(chartStart.count)
            let start = chartFaces.count
            let seedNormal = normals[seed]
            var axis = seedNormal
            var members = 1
            chartOf[seed] = cid
            chartFaces.append(Int32(seed))
            queue.removeAll(keepingCapacity: true)
            queue.append(Int32(seed))
            var head = 0
            while head < queue.count {
                let t = Int(queue[head]); head += 1
                for k in 0..<3 {
                    let u = Int(neighbor[t * 3 + k])
                    if u < 0 || chartOf[u] >= 0 { continue }
                    let n = normals[u]
                    if simd_dot(n, axis) < cosAverage { continue }
                    if simd_dot(n, seedNormal) < cosSeed { continue }
                    chartOf[u] = cid
                    chartFaces.append(Int32(u))
                    queue.append(Int32(u))
                    members += 1
                    // 走る平均。1 枚ずつ基準を引きずるので、板の継ぎ目程度の
                    // 段差は吸収しつつ、角では止まる。
                    axis = simd_normalize(axis + (n - axis) / Float(members))
                }
            }
            chartStart.append(start)
            chartCount.append(members)
            chartAxis.append(axis)
        }
        timings.grow = lap()

        // 4. チャートを平均平面へ射影し、bbox が最小になる回転を選ぶ
        //
        // 回転を試すのは詰めのため。細長いチャートが斜めに寝ていると bbox が
        // 無駄に大きくなる。15 度刻みの 6 通りで十分（90 度は同じ形）。
        struct Placement {
            var ex = SIMD3<Float>(1, 0, 0)
            var ey = SIMD3<Float>(0, 1, 0)
            var minX: Float = 0, minY: Float = 0
            var width: Float = 0, height: Float = 0   // m
            var originX = 0, originY = 0              // texel
        }
        var places = [Placement](repeating: Placement(), count: chartStart.count)
        var xs = [Float](); var ys = [Float]()
        for c in 0..<chartStart.count {
            let axis = chartAxis[c]
            let helper = abs(axis.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let ex0 = simd_normalize(simd_cross(axis, helper))
            let ey0 = simd_cross(axis, ex0)

            xs.removeAll(keepingCapacity: true); ys.removeAll(keepingCapacity: true)
            for i in 0..<chartCount[c] {
                let t = Int(chartFaces[chartStart[c] + i])
                for k in 0..<3 {
                    let p = vertices[Int(indices[t * 3 + k])]
                    xs.append(simd_dot(p, ex0)); ys.append(simd_dot(p, ey0))
                }
            }

            var best = Placement(ex: ex0, ey: ey0, minX: 0, minY: 0, width: 0, height: 0)
            var bestArea = Float.greatestFiniteMagnitude
            for step in 0..<6 {
                let theta = Float(step) * 15 * .pi / 180
                let cs = cos(theta), sn = sin(theta)
                var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
                var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
                for i in 0..<xs.count {
                    let x = cs * xs[i] + sn * ys[i]
                    let y = -sn * xs[i] + cs * ys[i]
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                let w = maxX - minX, h = maxY - minY
                // 正方形に近いほど棚詰めが効くので、面積が同じなら縦横差の
                // 小さいほうを採る。
                let score = (w + 1e-4) * (h + 1e-4)
                if score < bestArea {
                    bestArea = score
                    best.ex = cs * ex0 + sn * ey0
                    best.ey = -sn * ex0 + cs * ey0
                    best.minX = minX; best.minY = minY
                    best.width = w; best.height = h
                }
            }
            places[c] = best
        }
        timings.project = lap()

        // 5. テクセル密度を二分探索する
        //
        // 密度を上げれば解像度は上がるが、棚詰めの高さがアトラスを超える。
        // 超えない最大の密度が最良。詰めは O(n) なので何度でも試せる。
        let order = (0..<places.count).sorted { places[$0].height > places[$1].height }
        let boxArea = places.reduce(Float(0)) { $0 + ($1.width + 1e-4) * ($1.height + 1e-4) }
        let maxSide = places.reduce(Float(0)) { max($0, max($1.width, $1.height)) }

        /// texel/m の密度で棚詰めして、使った高さを返す。入らなければ nil。
        func shelf(_ density: Float, record: Bool) -> Int? {
            let limit = atlasSize
            var x = 0, y = 0, rowHeight = 0
            for c in order {
                let w = Int((places[c].width * density).rounded(.up)) + 2 * gutter
                let h = Int((places[c].height * density).rounded(.up)) + 2 * gutter
                if w > limit || h > limit { return nil }
                if x + w > limit {
                    y += rowHeight; x = 0; rowHeight = 0
                }
                if y + h > limit { return nil }
                if record { places[c].originX = x; places[c].originY = y }
                x += w
                rowHeight = max(rowHeight, h)
            }
            return y + rowHeight
        }

        var hi = boxArea > 0 ? Float(atlasSize) / sqrt(boxArea) : 1
        if maxSide > 0 { hi = min(hi, Float(atlasSize - 2 * gutter) / maxSide) }
        var lo = hi / 8
        var guard0 = 0
        while shelf(lo, record: false) == nil, guard0 < 24 { lo /= 2; guard0 += 1 }
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if shelf(mid, record: false) != nil { lo = mid } else { hi = mid }
        }
        let density = lo
        _ = shelf(density, record: true)
        timings.pack = lap()

        // 6. 頂点を書き出す
        //
        // 同じ頂点がチャートをまたぐと UV が別になるので複製する。チャート内
        // では共有する（複製すると描画時に面ごとに割れて見える）。
        var outVertices = [SIMD3<Float>](); outVertices.reserveCapacity(faceCount * 2)
        var outUVs = [SIMD2<Float>](); outUVs.reserveCapacity(faceCount * 2)
        var outIndices = [UInt32](); outIndices.reserveCapacity(faceCount * 3)
        var map = [UInt32: UInt32](minimumCapacity: 1024)
        let scale = 1 / Float(atlasSize)

        for c in 0..<places.count {
            let p = places[c]
            map.removeAll(keepingCapacity: true)
            let ox = Float(p.originX + gutter), oy = Float(p.originY + gutter)
            for i in 0..<chartCount[c] {
                let t = Int(chartFaces[chartStart[c] + i])
                for k in 0..<3 {
                    let vi = indices[t * 3 + k]
                    if let existing = map[vi] {
                        outIndices.append(existing)
                        continue
                    }
                    let world = vertices[Int(vi)]
                    let x = (simd_dot(world, p.ex) - p.minX) * density + ox
                    let y = (simd_dot(world, p.ey) - p.minY) * density + oy
                    let index = UInt32(outVertices.count)
                    outVertices.append(world)
                    outUVs.append(SIMD2(x * scale, y * scale))
                    map[vi] = index
                    outIndices.append(index)
                }
            }
        }
        timings.emit = lap()

        let surface = areas.reduce(0, +)                       // m2
        let texels = Float(atlasSize * atlasSize)
        return Result(
            vertices: outVertices, uvs: outUVs, indices: outIndices,
            atlasSize: atlasSize,
            chartCount: places.count,
            mmPerTexel: density > 0 ? 1000 / density : 0,
            fill: texels > 0 ? surface * density * density / texels : 0,
            timings: timings)
    }
}
