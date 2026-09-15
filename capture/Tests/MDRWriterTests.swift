import XCTest
@testable import MadoribaCapture

/// 面分類の書き出し。**平面図に足りない唯一の情報**なので、
/// 数え方と名前の対応だけは固定しておく。
final class MDRWriterTests: XCTestCase {

    /// `ARMeshClassification` の生値との対応。**順番がずれると扉が窓になる。**
    func testLabelOrderMatchesARKit() {
        XCTAssertEqual(MDRWriter.classNames.count, 8)
        XCTAssertEqual(MDRWriter.classNames[0], "none")
        XCTAssertEqual(MDRWriter.classNames[1], "wall")
        XCTAssertEqual(MDRWriter.classNames[2], "floor")
        XCTAssertEqual(MDRWriter.classNames[3], "ceiling")
        XCTAssertEqual(MDRWriter.classNames[6], "window")
        XCTAssertEqual(MDRWriter.classNames[7], "door")
    }

    func testHistogramCountsEachLabel() {
        let h = MDRWriter.classHistogram([1, 1, 1, 2, 7, 6, 6, 0])
        XCTAssertEqual(h["wall"], 3)
        XCTAssertEqual(h["floor"], 1)
        XCTAssertEqual(h["door"], 1)
        XCTAssertEqual(h["window"], 2)
        XCTAssertEqual(h["none"], 1)
        XCTAssertNil(h["ceiling"])
    }

    /// 将来 ARKit が分類を増やしても落とさない。
    func testUnknownLabelIsKeptNotDropped() {
        let h = MDRWriter.classHistogram([9, 9])
        XCTAssertEqual(h["unknown-9"], 2)
    }

    func testEmptyMeshGivesEmptyHistogram() {
        XCTAssertTrue(MDRWriter.classHistogram([]).isEmpty)
    }

    /// **合流であって書き直しではない。** RoomPlan の統計を足すときに
    /// 焼き込みの記録を消してしまうと、同居の可否を判断する材料が無くなる。
    func testMergeKeepsTheExistingBakeRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bake.json")
        try JSONSerialization.data(withJSONObject: [
            "elapsed_sec": 1.47,
            "stages_sec": ["unwrap": 0.054],
        ]).write(to: url)

        CaptureSession.mergeIntoBakeJSON(["roomplan": ["enabled": true, "walls": 4]], at: dir)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(root["elapsed_sec"] as? Double), 1.47, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap((root["stages_sec"] as? [String: Any])?["unwrap"] as? Double),
                       0.054, accuracy: 1e-9)
        XCTAssertEqual((root["roomplan"] as? [String: Any])?["walls"] as? Int, 4)
    }

    /// 焼き込みが失敗して bake.json が無くても、RoomPlan の記録は残す。
    func testMergeCreatesTheFileWhenMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        CaptureSession.mergeIntoBakeJSON(["roomplan": ["enabled": false]], at: dir)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: dir.appendingPathComponent("bake.json"))) as? [String: Any])
        XCTAssertEqual((root["roomplan"] as? [String: Any])?["enabled"] as? Bool, false)
    }
}

/// 映像フォーマットの選択。**iPhone 対応で初めて効く。**
final class VideoFormatTests: XCTestCase {

    /// iPad8,11 でこれまで選ばれてきた 1920x1440 が引き続き選ばれること。
    func testIPadKeepsTheSameFormat() {
        let sizes = [(w: 1920, h: 1440, fps: 30), (w: 1280, h: 720, fps: 60),
                     (w: 1440, h: 1080, fps: 30)]
        XCTAssertEqual(DeviceProbe.pickFormat(from: sizes), 0)
    }

    /// **4K は採らない。** 焼き込みは 960 幅へ縮小するので画質は上がらず、
    /// JPEG の負荷とバンドル容量だけが増える。
    func testFourKIsRejectedInFavourOfHD() {
        let sizes = [(w: 3840, h: 2160, fps: 30), (w: 1920, h: 1080, fps: 30),
                     (w: 1280, h: 720, fps: 30)]
        XCTAssertEqual(DeviceProbe.pickFormat(from: sizes), 1)
    }

    /// 30fps が無ければそこから選ぶ。
    func testFallsBackWhenNoThirtyFps() {
        let sizes = [(w: 1920, h: 1080, fps: 60), (w: 1280, h: 720, fps: 60)]
        XCTAssertEqual(DeviceProbe.pickFormat(from: sizes), 0)
    }

    /// 上限を超えるものしか無ければ、一番小さいものを採る。
    func testPicksSmallestWhenEverythingExceedsTheCap() {
        let sizes = [(w: 3840, h: 2160, fps: 30), (w: 4096, h: 3072, fps: 30)]
        XCTAssertEqual(DeviceProbe.pickFormat(from: sizes), 0)
    }

    func testEmptyIsNil() {
        XCTAssertNil(DeviceProbe.pickFormat(from: []))
    }
}
