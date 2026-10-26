import XCTest
@testable import VenusTaskCore

final class TaskVoiceHoldTests: XCTestCase {
    private let button = CGRect(x: 60, y: 680, width: 240, height: 48)

    func testDefaultReleaseRequestsTextOnlyOnce() {
        var hold = TaskVoiceHold()
        let token = hold.begin()
        XCTAssertTrue(hold.isActive)
        XCTAssertTrue(hold.release())
        XCTAssertEqual(hold.phase, .released)
        XCTAssertTrue(hold.accepts(token))
        XCTAssertFalse(hold.isActive)
        XCTAssertFalse(hold.release())
    }

    func testCancelOnReleaseRejectsLateRecognitionAndRepeatedRelease() {
        var hold = TaskVoiceHold()
        let token = hold.begin(), region = TaskVoiceHold.cancelRegion(above: button)
        hold.move(to: CGPoint(x: region.midX, y: region.midY), cancelRegion: region)
        XCTAssertTrue(hold.cancelsOnRelease)
        XCTAssertFalse(hold.release())
        XCTAssertEqual(hold.phase, .cancelled)
        XCTAssertFalse(hold.accepts(token))
        XCTAssertFalse(hold.release())
    }

    func testMovingBackUsesFinalLocationRatherThanEarlierCancelHover() {
        var hold = TaskVoiceHold()
        hold.begin()
        let region = TaskVoiceHold.cancelRegion(above: button)
        hold.move(to: CGPoint(x: region.midX, y: region.midY), cancelRegion: region)
        hold.move(to: CGPoint(x: button.midX, y: button.midY), cancelRegion: region)
        XCTAssertFalse(hold.cancelsOnRelease)
        XCTAssertTrue(hold.release())
        // A held finger or a late gesture callback cannot revive a completed recording.
        hold.move(to: CGPoint(x: region.midX, y: region.midY), cancelRegion: region)
        XCTAssertEqual(hold.phase, .released)
        XCTAssertFalse(hold.release())
    }

    func testInterruptionInvalidatesPermissionAndRecognitionTokens() {
        var hold = TaskVoiceHold()
        let old = hold.begin()
        hold.cancel()
        XCTAssertFalse(hold.accepts(old))
        XCTAssertFalse(hold.release())
        let new = hold.begin()
        XCTAssertFalse(hold.accepts(old))
        XCTAssertTrue(hold.accepts(new))
        hold.release(); hold.cancel()
        XCTAssertFalse(hold.accepts(new))
    }

    func testCancelTargetIsAboveComposerAndIncludesTouchPadding() {
        let region = TaskVoiceHold.cancelRegion(above: button)
        XCTAssertEqual(region.midX, button.midX)
        XCTAssertEqual(region.size, CGSize(width: 88, height: 88))
        XCTAssertLessThan(region.maxY, button.minY)
        // The visible circle is 64 pt; its surrounding 12 pt is also a cancel target.
        XCTAssertTrue(region.contains(CGPoint(x: region.midX + 40, y: region.midY)))
        XCTAssertFalse(region.contains(CGPoint(x: region.maxX + 1, y: region.midY)))
        XCTAssertFalse(region.intersects(button))
    }

    func testUnknownGeometryNeverAccidentallyCancels() {
        var hold = TaskVoiceHold()
        hold.begin()
        let region = TaskVoiceHold.cancelRegion(above: .zero)
        XCTAssertTrue(region.isEmpty)
        hold.move(to: .zero, cancelRegion: region)
        XCTAssertTrue(hold.release())
    }
}
