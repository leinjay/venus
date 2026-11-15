import XCTest
@testable import VenusRecordingCore

final class RecordingSentenceTests: XCTestCase {
    func testNaturalSentencesPreserveDecimalAndText() {
        XCTAssertEqual(RecordingSentences.split("预算3.5万元。明天确认！可以吗？"), ["预算3.5万元。", "明天确认！", "可以吗？"])
    }
    func testEstimatedSentenceTimesCoverOriginalWindowAndKeepSpeaker() {
        let line = RecordingTranscriptLine(start: 20, end: 40, speakerID: 2, text: "第一句。第二句更长。")
        let result = RecordingSentences.lines(line)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.start, 20)
        XCTAssertEqual(result.last?.end, 40)
        XCTAssertEqual(result[0].end, result[1].start)
        XCTAssertTrue(result.allSatisfy { $0.speakerID == 2 })
        XCTAssertEqual(result.map(\.id), RecordingSentences.lines(line).map(\.id))
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
    }
}
