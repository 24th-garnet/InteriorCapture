import XCTest
@testable import MadoribaCapture

/// 過去のスキャンの一覧が、バンドルの中身どおりに読めることを押さえる。
///
/// 一覧は「開けるはずのものが開けない」形で壊れる。`room.json` があるのに
/// 平面図ボタンが無効、日付が読めず並び順が狂う、といった誤りは実機で
/// 触るまで気づけないので、走査の部分をここで固定する。
final class ScanLibraryTests: XCTestCase {

    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func makeBundle(_ name: String, manifest: [String: Any]?,
                            files: [String] = []) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let m = manifest {
            try JSONSerialization.data(withJSONObject: m)
                .write(to: url.appendingPathComponent("manifest.json"))
        }
        for f in files {
            try Data("x".utf8).write(to: url.appendingPathComponent(f))
        }
        return url
    }

    func testOnlyMdrDirectoriesAreListed() throws {
        _ = try makeBundle("room-aaa.mdr", manifest: nil)
        _ = try makeBundle("Scaniverse", manifest: nil)
        try Data("x".utf8).write(to: root.appendingPathComponent("deviceprobe.txt"))

        let scans = ScanLibrary.enumerate(in: root)
        XCTAssertEqual(scans.map { $0.title }, ["room-aaa"])
    }

    func testMetadataComesFromTheManifest() throws {
        _ = try makeBundle("room-bbb.mdr", manifest: [
            "created_at": "2026-09-07T09:40:25Z",
            "frame_count": 292,
            "duration_sec": 64.6,
            "device": ["model": "iPad8,11"],
            "world_alignment": "gravity",
        ], files: ["room.json", "mesh.usdz", "mesh.glb"])

        let scan = try XCTUnwrap(ScanLibrary.enumerate(in: root).first)
        XCTAssertEqual(scan.frameCount, 292)
        XCTAssertEqual(try XCTUnwrap(scan.durationSec), 64.6, accuracy: 0.01)
        XCTAssertEqual(scan.deviceModel, "iPad8,11")
        XCTAssertTrue(scan.hasRoom)
        XCTAssertTrue(scan.hasUSDZ)
        XCTAssertTrue(scan.hasGLB)
        XCTAssertFalse(scan.hasFixes)
        // 小数秒なしの ISO8601 も読めること。読めないと並び順が狂う
        XCTAssertNotNil(scan.createdAt)
    }

    func testFractionalSecondsDateIsAlsoParsed() throws {
        _ = try makeBundle("room-ccc.mdr",
                           manifest: ["created_at": "2026-09-07T09:40:25.123Z"])
        let scan = try XCTUnwrap(ScanLibrary.enumerate(in: root).first)
        XCTAssertNotNil(scan.createdAt)
    }

    func testNewestFirst() throws {
        _ = try makeBundle("room-old.mdr", manifest: ["created_at": "2026-01-01T00:00:00Z"])
        _ = try makeBundle("room-new.mdr", manifest: ["created_at": "2026-09-07T00:00:00Z"])
        XCTAssertEqual(ScanLibrary.enumerate(in: root).map { $0.title },
                       ["room-new", "room-old"])
    }

    /// **取れていない撮影に北を与えない。** 嘘の方位を図に載せないため。
    func testNorthOnlyWhenTheHeadingWasUsable() throws {
        _ = try makeBundle("room-a.mdr", manifest: ["world_alignment": "gravity"])
        XCTAssertNil(try XCTUnwrap(ScanLibrary.enumerate(in: root).first).north)

        try? FileManager.default.removeItem(at: root.appendingPathComponent("room-a.mdr"))
        _ = try makeBundle("room-b.mdr", manifest: [
            "world_alignment": "gravityAndHeading",
            "heading": ["available": true, "usable": false, "accuracy_deg": 45.0],
        ])
        XCTAssertNil(try XCTUnwrap(ScanLibrary.enumerate(in: root).first).north)

        try? FileManager.default.removeItem(at: root.appendingPathComponent("room-b.mdr"))
        _ = try makeBundle("room-c.mdr", manifest: [
            "world_alignment": "gravityAndHeading",
            "heading": ["available": true, "usable": true, "accuracy_deg": 8.0],
        ])
        let n = try XCTUnwrap(try XCTUnwrap(ScanLibrary.enumerate(in: root).first).north)
        XCTAssertEqual(n, SIMD2(0, -1), "+X が東 / +Z が南なので北は -Z")
    }

    func testFixesAreDetected() throws {
        _ = try makeBundle("room-d.mdr", manifest: nil,
                           files: [PlanCorrections.fileName])
        XCTAssertTrue(try XCTUnwrap(ScanLibrary.enumerate(in: root).first).hasFixes)
    }

    /// manifest が壊れていても一覧から落とさない。落とすと開く手段が無くなる。
    func testBrokenManifestStillLists() throws {
        let url = try makeBundle("room-e.mdr", manifest: nil)
        try Data("{ これは JSON ではない".utf8)
            .write(to: url.appendingPathComponent("manifest.json"))
        let scan = try XCTUnwrap(ScanLibrary.enumerate(in: root).first)
        XCTAssertEqual(scan.title, "room-e")
        XCTAssertNil(scan.frameCount)
        XCTAssertNotNil(scan.createdAt, "日付はファイルの更新時刻で埋める")
    }
}

// MARK: 焼き込みの素性

extension ScanLibraryTests {

    /// bake.json から構成と展開時間を読み、遅さを**構成の記憶に頼らず**判定する。
    func testBakeProvenanceIsRead() throws {
        let url = try makeBundle("room-bake.mdr", manifest: nil)
        try JSONSerialization.data(withJSONObject: [
            "elapsed_sec": 14.54,
            "triangles": 148_897,
            "build_configuration": "Release",
            "thermal_state": "fair",
            "stages_sec": ["unwrap": 13.91, "rasterize": 0.07,
                           "project": 0.49, "resolve": 0.04],
        ]).write(to: url.appendingPathComponent("bake.json"))

        let scan = try XCTUnwrap(ScanLibrary.enumerate(in: root).first)
        XCTAssertEqual(try XCTUnwrap(scan.bakeUnwrapSec), 13.91, accuracy: 0.01)
        XCTAssertEqual(scan.bakeTriangles, 148_897)
        XCTAssertEqual(scan.bakeConfiguration, "Release")
        XCTAssertEqual(scan.bakeThermal, "fair")
        // 実測の基準そのものなので 1 倍付近になる
        let x = try XCTUnwrap(scan.bakeSlowdown)
        XCTAssertEqual(x, 1.0, accuracy: 0.05)
        XCTAssertLessThan(x, BuildInfo.Metrics.slowdownAlarm)
    }

    /// -O0 の実測（同じ面数で 6.5 倍）を入れたら異常として出る。
    func testUnoptimizedBakeIsFlagged() throws {
        let url = try makeBundle("room-slow.mdr", manifest: nil)
        try JSONSerialization.data(withJSONObject: [
            "triangles": 148_897,
            "build_configuration": "Debug",
            "stages_sec": ["unwrap": 13.91 * 6.5],
        ]).write(to: url.appendingPathComponent("bake.json"))

        let scan = try XCTUnwrap(ScanLibrary.enumerate(in: root).first)
        let x = try XCTUnwrap(scan.bakeSlowdown)
        XCTAssertEqual(x, 6.5, accuracy: 0.2)
        XCTAssertGreaterThan(x, BuildInfo.Metrics.slowdownAlarm)
    }

    /// **面数で割る理由。** 面数が違う撮影を秒数で比べても速いか遅いか
    /// 分からない。半分の面数なら半分の秒数でも同じ速さ。
    func testSecondsAloneCannotDetectSlowness() {
        let fast = BuildInfo.Metrics.slowdown(unwrapSec: 7.0, triangles: 74_000)
        let slow = BuildInfo.Metrics.slowdown(unwrapSec: 7.0, triangles: 12_000)
        XCTAssertEqual(try! XCTUnwrap(fast), 1.0, accuracy: 0.1)
        XCTAssertGreaterThan(try! XCTUnwrap(slow), BuildInfo.Metrics.slowdownAlarm)
    }

    func testMissingBakeJSONIsNotAnError() throws {
        _ = try makeBundle("room-nobake.mdr", manifest: nil)
        let scan = try XCTUnwrap(ScanLibrary.enumerate(in: root).first)
        XCTAssertNil(scan.bakeUnwrapSec)
        XCTAssertNil(scan.bakeSlowdown)
    }
}
