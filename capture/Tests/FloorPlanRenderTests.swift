import RoomPlan
import SwiftUI
import XCTest
@testable import MadoribaCapture

/// 作図を実際に描かせて画像に落とす。
///
/// 数値の一致だけでは足りない。弧の向き、寸法線の側、ラベルの位置は
/// 計算が合っていても見た目が壊れる。**描かせて見る**のが唯一の確認。
@available(iOS 17.0, *)
final class FloorPlanRenderTests: XCTestCase {

    private func loadRoom() throws -> CapturedRoom {
        let url = try XCTUnwrap(Bundle(for: FloorPlanRenderTests.self)
            .url(forResource: "room-33d49373", withExtension: "json"))
        return try JSONDecoder().decode(CapturedRoom.self, from: try Data(contentsOf: url))
    }

    @MainActor
    private func render(_ plan: FloorPlan, to name: String,
                        highlight: Bool = true) throws {
        let view = FloorPlanCanvas(plan: plan, highlightMedium: highlight)
            .frame(width: 680, height: 680)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "描画に失敗した")
        let data = try XCTUnwrap(image.pngData())
        let out = URL(fileURLWithPath: "/tmp/\(name)")
        try? data.write(to: out)
        add(XCTAttachment(data: data, uniformTypeIdentifier: "public.png"))
        XCTAssertGreaterThan(data.count, 5_000, "空の画像が出ている")
    }

    @MainActor
    func testRendersTheCorrectedPlan() throws {
        let room = try loadRoom()
        // 端末での訂正を当てた状態。掃き出し窓を window に、椅子の箱を -0.35m
        var fixes = PlanCorrections()
        let plain = FloorPlan(room: room)
        let wide = try XCTUnwrap(plain.openings.max { $0.width < $1.width })
        fixes.openings[wide.id.uuidString] = "window"
        if let chair = plain.furniture.first(where: { $0.category == .chair }) {
            fixes.boxes[chair.id.uuidString] = .init(dx: 0, dy: 0, dz: -0.35)
        }
        let fixed = FloorPlan(room: room, corrections: fixes, north: SIMD2(0, -1))
        try render(fixed, to: "madoriba_plan_ios.png")
        // 清書（要確認の強調なし）。販売図面として出すのはこちら。
        try render(fixed, to: "madoriba_plan_ios_clean.png", highlight: false)
    }

    @MainActor
    func testRendersTheRawPlan() throws {
        try render(FloorPlan(room: try loadRoom()), to: "madoriba_plan_ios_raw.png")
    }
}
