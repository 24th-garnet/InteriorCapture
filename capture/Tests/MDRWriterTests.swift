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
}
