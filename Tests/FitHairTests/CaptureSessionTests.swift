import XCTest
@testable import FitHair

@MainActor
final class CaptureSessionTests: XCTestCase {
    func testLeavingDuringCountdownNeverStartsTheBurst() async {
        let waiting = expectation(description: "countdown started")
        let gate = TestGate()
        let session = CaptureSession(sleep: { _ in waiting.fulfill(); await gate.wait() })
        var captured = false
        var completed = false
        session.start(countdownEnabled: true, capture: { captured = true; return [] }, completion: { _ in completed = true })
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertEqual(session.countdown, 3)

        let pending = session.cancel()
        gate.open()
        await pending?.value

        XCTAssertFalse(session.isShooting)
        XCTAssertNil(session.countdown)
        XCTAssertFalse(captured)
        XCTAssertFalse(completed)
    }

    func testCancelledBurstCannotPublishEvenIfCameraIgnoresCancellation() async throws {
        let waiting = expectation(description: "burst started")
        let gate = TestGate()
        let session = CaptureSession()
        let image = try testImage()
        var completed = false
        session.start(countdownEnabled: false, capture: {
            waiting.fulfill()
            await gate.wait()
            return [image]
        }, completion: { _ in completed = true })
        await fulfillment(of: [waiting], timeout: 2)

        let pending = session.cancel()
        gate.open()
        await pending?.value

        XCTAssertFalse(completed)
        XCTAssertFalse(session.isShooting)
    }

    func testNewShutterWorksAfterCancellationAndOldBurstCannotReplaceIt() async throws {
        let waiting = expectation(description: "old burst started")
        let finished = expectation(description: "new burst finished")
        let gate = TestGate()
        let session = CaptureSession()
        let image = try testImage()
        var completions = [String]()
        session.start(countdownEnabled: false, capture: {
            waiting.fulfill(); await gate.wait(); return [image]
        }, completion: { _ in completions.append("old") })
        await fulfillment(of: [waiting], timeout: 2)
        let pending = session.cancel()
        session.start(countdownEnabled: false, capture: { [image] }, completion: { _ in
            completions.append("new")
            finished.fulfill()
        })
        await fulfillment(of: [finished], timeout: 2)
        gate.open()
        await pending?.value
        XCTAssertEqual(completions, ["new"])
    }
}

@MainActor
final class TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

func testImage() throws -> CGImage {
    let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    return try XCTUnwrap(context.makeImage())
}
