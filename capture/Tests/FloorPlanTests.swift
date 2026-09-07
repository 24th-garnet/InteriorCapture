import RoomPlan
import XCTest
import simd
@testable import MadoribaCapture

/// 端末側に移した平面図の幾何が、Python 側（`recon/mdr2colmap/roomplan.py`）と
/// **同じ数値を出す**ことを実データで押さえる。
///
/// 移植は「動くように見えて数値が違う」形で壊れる。壁の長さが数 cm 違っても
/// 図はそれらしく描けてしまうので、期待値は Python の実測結果を直接書く。
@available(iOS 17.0, *)
final class FloorPlanTests: XCTestCase {

    /// `recon/.venv/bin/python -m mdr2colmap.cli roomplan …` の出力
    /// （room-33d49373）から取った期待値。
    private enum Expected {
        static let area = 11.28790          // 壁ループの内法
        static let displayArea = 11.28      // 小数第 2 位以下切り捨て
        static let displayTatami = 6.9      // 1 帖 = 1.62 m2、切り捨て
        static let ceilingHeight = 2.43
        static let wallLengths = [3.135, 3.135, 3.6, 3.6]
        static let doorWidths = [0.700, 0.707, 1.736]
        static let roomName = "洋室"
        static let furniture = 4
    }

    private func loadRoom() throws -> CapturedRoom {
        let url = try XCTUnwrap(
            Bundle(for: FloorPlanTests.self)
                .url(forResource: "room-33d49373", withExtension: "json"),
            "Tests/Fixtures/room-33d49373.json が見つからない")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CapturedRoom.self, from: data)
    }

    func testWallsMatchThePythonPath() throws {
        let plan = FloorPlan(room: try loadRoom())
        XCTAssertEqual(plan.walls.count, 4)
        let lengths = plan.walls.map { $0.length }.sorted()
        for (got, want) in zip(lengths, Expected.wallLengths) {
            XCTAssertEqual(got, want, accuracy: 0.002, "壁の長さが Python と違う")
        }
        XCTAssertEqual(plan.ceilingHeight, Expected.ceilingHeight, accuracy: 0.005)
    }

    func testAreaComesFromTheWallLoop() throws {
        let plan = FloorPlan(room: try loadRoom())
        XCTAssertNotNil(plan.polygon, "4 枚の壁は閉じるべき")
        XCTAssertEqual(plan.areaSource, .walls)
        XCTAssertEqual(plan.area, Expected.area, accuracy: 0.001)
    }

    /// 公正競争規約の表示規則。**切り上げ・四捨五入は実際より広く見せる。**
    func testDisplayRulesTruncate() throws {
        let plan = FloorPlan(room: try loadRoom())
        XCTAssertEqual(FloorPlan.displayArea(plan.area), Expected.displayArea, accuracy: 1e-9)
        XCTAssertEqual(FloorPlan.displayTatami(plan.area), Expected.displayTatami,
                       accuracy: 1e-9)
        // 帖 1 枚が 1.62 m2 以上あることを満たす
        XCTAssertLessThanOrEqual(Expected.displayTatami * FloorPlan.tatamiArea, plan.area)
        XCTAssertGreaterThan((Expected.displayTatami + 0.1) * FloorPlan.tatamiArea, plan.area)
    }

    func testOpeningsAreAssignedToTheirParentWall() throws {
        let plan = FloorPlan(room: try loadRoom())
        // RoomPlan の分類のまま読む。実データは 3 件すべて door
        XCTAssertEqual(plan.openings(.door).count, 3)
        XCTAssertEqual(plan.openings(.window).count, 0)
        let widths = plan.openings(.door).map { $0.width }.sorted()
        for (got, want) in zip(widths, Expected.doorWidths) {
            XCTAssertEqual(got, want, accuracy: 0.002)
        }
        // 3 件が別々の壁に付く（1 枚だけ開口なし）
        let walled = Set(plan.openings.map { $0.wallID })
        XCTAssertEqual(walled.count, 3)
        XCTAssertEqual(plan.walls.filter { $0.openings.isEmpty }.count, 1)
        // 下端はいずれも床。窓との区別に使えないことの確認でもある
        for o in plan.openings {
            XCTAssertEqual(o.sill, 0, accuracy: 0.01)
        }
    }

    func testSolidSpansBreakTheWallAtTheOpening() throws {
        let plan = FloorPlan(room: try loadRoom())
        for w in plan.walls {
            let total = w.solidSpans.reduce(0.0) { $0 + ($1.1 - $1.0) }
            let opened = w.openings.reduce(0.0) { $0 + $1.width }
            XCTAssertEqual(total, w.length - opened, accuracy: 0.01,
                           "実体部分 = 壁長 - 開口幅")
        }
    }

    func testRoomNameComesFromTheSection() throws {
        let plan = FloorPlan(room: try loadRoom())
        XCTAssertEqual(plan.roomName, Expected.roomName)
        XCTAssertEqual(plan.furniture.count, Expected.furniture)
    }

    // MARK: 訂正

    /// 実測で椅子の箱が Z 方向に 35cm ずれていた。訂正が中心だけを動かす。
    func testBoxCorrectionMovesOnlyTheCenter() throws {
        let room = try loadRoom()
        let plain = FloorPlan(room: room)
        let chair = try XCTUnwrap(plain.furniture.first { $0.category == .chair })

        var fixes = PlanCorrections()
        fixes.boxes[chair.id.uuidString] = .init(dx: 0, dy: 0, dz: -0.35)
        let fixed = FloorPlan(room: room, corrections: fixes)
        let moved = try XCTUnwrap(fixed.furniture.first { $0.id == chair.id })

        XCTAssertEqual(moved.center.x, chair.center.x, accuracy: 1e-9)
        XCTAssertEqual(moved.center.y, chair.center.y - 0.35, accuracy: 1e-9)
        XCTAssertEqual(moved.halfWidth, chair.halfWidth, accuracy: 1e-9)
        XCTAssertEqual(moved.halfDepth, chair.halfDepth, accuracy: 1e-9)
        XCTAssertEqual(moved.yaw, chair.yaw, accuracy: 1e-9)
        // 他の家具は動かない
        let bed = try XCTUnwrap(plain.furniture.first { $0.category == .bed })
        let bedAfter = try XCTUnwrap(fixed.furniture.first { $0.id == bed.id })
        XCTAssertEqual(bedAfter.center, bed.center)
    }

    /// 実測で幅 1736mm の掃き出し窓が `doors` に入っていた。
    /// 下端 0mm・幅ともに戸としてあり得るので幾何では見分けられない。
    func testOpeningCategoryCanBeCorrected() throws {
        let room = try loadRoom()
        let plain = FloorPlan(room: room)
        let wide = try XCTUnwrap(plain.openings.max { $0.width < $1.width })
        XCTAssertEqual(wide.width, 1.736, accuracy: 0.002)
        XCTAssertEqual(wide.category, .door)
        XCTAssertEqual(wide.confidence, .medium)

        var fixes = PlanCorrections()
        fixes.openings[wide.id.uuidString] = "window"
        let fixed = FloorPlan(room: room, corrections: fixes)
        XCTAssertEqual(fixed.openings(.window).count, 1)
        XCTAssertEqual(fixed.openings(.door).count, 2)
        // 幅・位置・下端は RoomPlan の値のまま
        let got = try XCTUnwrap(fixed.openings.first { $0.id == wide.id })
        XCTAssertEqual(got.width, wide.width, accuracy: 1e-9)
        XCTAssertEqual(got.start, wide.start, accuracy: 1e-9)
        XCTAssertEqual(got.sill, wide.sill, accuracy: 1e-9)
    }

    func testCorrectionsRoundTripThroughTheBundleFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var fixes = PlanCorrections()
        fixes.boxes["BOX"] = .init(dx: 0, dy: 0, dz: -0.35)
        fixes.openings["OPEN"] = "window"
        XCTAssertTrue(fixes.write(to: dir, note: "テスト"))

        let back = PlanCorrections.load(from: dir)
        XCTAssertEqual(back.openings["OPEN"], "window")
        XCTAssertEqual(back.boxes["BOX"]?.dz ?? 0, -0.35, accuracy: 1e-9)

        // Python 側と同じ形（boxes / openings キー）で書けている
        let data = try Data(contentsOf: dir.appendingPathComponent("fixes.json"))
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(obj["boxes"])
        XCTAssertNotNil(obj["openings"])
        XCTAssertNotNil(obj["_note"], "数値だけでは後から検算できない")
    }

    // MARK: 方位

    /// 取れていないときは北を持たない。嘘の方位を図に載せないため。
    func testNorthIsOptional() throws {
        let room = try loadRoom()
        XCTAssertNil(FloorPlan(room: room).north)
        let n = FloorPlan(room: room, north: SIMD2(0, -1)).north
        XCTAssertEqual(try XCTUnwrap(n), SIMD2(0, -1))
    }

    // MARK: 画面座標

    /// **+Z は画面下。** 反転すると鏡像の間取り図になり、3D と見比べたときに
    /// ドアが逆側に出る。
    func testPlanTransformPutsPositiveZDown() {
        let t = PlanTransform.fit((minX: 0, minZ: 0, maxX: 4, maxZ: 3),
                                 in: CGSize(width: 400, height: 400), pad: 0)
        let origin = t.point(SIMD2(0, 0))
        let down = t.point(SIMD2(0, 1))
        let right = t.point(SIMD2(1, 0))
        XCTAssertGreaterThan(down.y, origin.y, "+Z は画面下")
        XCTAssertGreaterThan(right.x, origin.x, "+X は画面右")
        // 往復する
        let back = t.world(t.point(SIMD2(2.5, 1.5)))
        XCTAssertEqual(back.x, 2.5, accuracy: 1e-6)
        XCTAssertEqual(back.y, 1.5, accuracy: 1e-6)
    }
}
