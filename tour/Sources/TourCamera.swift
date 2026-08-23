import Foundation
import simd

/// station 間の移動と、各 station での見回しを扱う。
///
/// 自由飛行にしないのは 3DGS の性質による（Tour.swift 参照）。
/// 移動は station 間の補間で行い、到着後は自由に見回せる。
@MainActor
final class TourCamera: ObservableObject {

    @Published private(set) var currentStation: Int = 0
    @Published private(set) var isMoving = false

    /// 水平方向の向き（ラジアン）。+Z を 0 として反時計回り。
    private(set) var yaw: Float = 0
    /// 上下の向き。真上・真下は見せない（天井と床は撮影が薄く破綻しやすい）。
    private(set) var pitch: Float = 0

    private let tour: Tour
    private var origin: SIMD3<Float>
    private var target: SIMD3<Float>
    private var moveProgress: Float = 1.0
    /// station 間の移動にかける秒数。速すぎると酔い、遅いと待たされる。
    private let moveDuration: Float = 0.55

    static let pitchLimit: Float = .pi / 2 * 0.85

    init(tour: Tour) {
        self.tour = tour
        let first = tour.stations.first
        origin = first?.pos ?? .zero
        target = origin
        if let f = first?.fwd {
            yaw = atan2(f.x, f.z)
        }
    }

    var eyePosition: SIMD3<Float> {
        let t = smoothstep(moveProgress)
        var p = mix(origin, target, t: SIMD3(repeating: t))
        // 撮影時の手の高さではなく、立って見た高さに揃える
        p.y = tour.floorY + tour.eyeHeight
        return p
    }

    var forward: SIMD3<Float> {
        SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
    }

    /// 右手系・Y 上の view 行列。
    var viewMatrix: simd_float4x4 {
        let eye = eyePosition
        let f = normalize(forward)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let s = normalize(cross(f, worldUp))
        let u = cross(s, f)
        // 3DGS の PLY は Y 下向きで書かれるのが慣例なので、描画側で上下を合わせる
        let r = simd_float4x4(
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        )
        return r
    }

    // MARK: - 操作

    func look(deltaYaw: Float, deltaPitch: Float) {
        yaw += deltaYaw
        pitch = max(-Self.pitchLimit, min(Self.pitchLimit, pitch + deltaPitch))
    }

    /// 見ている方向へ 1 station 進む。
    func advance() {
        guard let next = tour.step(from: currentStation, towards: forward) else { return }
        move(to: next)
    }

    func move(to index: Int) {
        guard index >= 0, index < tour.stations.count, index != currentStation || moveProgress < 1 else { return }
        origin = eyePosition
        target = tour.stations[index].pos
        moveProgress = 0
        currentStation = index
        isMoving = true
    }

    func update(deltaTime: Float) {
        guard moveProgress < 1 else { return }
        moveProgress = min(1, moveProgress + deltaTime / moveDuration)
        if moveProgress >= 1 { isMoving = false }
    }

    /// 加速して減速する補間。等速だと開始と停止が唐突に感じられる。
    private func smoothstep(_ t: Float) -> Float {
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }
}
