import XCTest
@testable import FitHair

@MainActor
final class TryOnRendererTests: XCTestCase {
    private func key(_ style: String, photoID: UUID, shade: String = "auto") -> TryOnRenderer.Key {
        .init(photoID: photoID, styleID: style, shadeID: shade)
    }

    private func output() throws -> HairTryOn.Output {
        let image = try testImage()
        return .init(image: image, original: image)
    }

    func testChangingStyleShadeOrPhotoNeverExposesThePreviousPreview() async throws {
        let renderer = TryOnRenderer()
        let photo = UUID()
        let first = key("f1", photoID: photo)
        let image = try output()
        await renderer.render(first) { image }
        XCTAssertNotNil(renderer.output(for: first))
        XCTAssertNil(renderer.output(for: key("f2", photoID: photo)))
        XCTAssertNil(renderer.output(for: key("f1", photoID: photo, shade: "blonde")))
        XCTAssertNil(renderer.output(for: key("f1", photoID: UUID())))
    }

    func testRefiningReplacesTheDraftOnceAndKeepsItWhenItFails() async throws {
        let renderer = TryOnRenderer()
        let photo = UUID()
        let first = key("f1", photoID: photo), second = key("f2", photoID: photo)
        let draft = try output(), better = try output()
        await renderer.render(first) { draft }
        await renderer.refine(first) { _ in better }
        XCTAssertTrue(renderer.output(for: first)?.image === better.image)
        XCTAssertFalse(renderer.isRefining(first))
        // Coming back to a refined preview doesn't redo the work.
        await renderer.render(first) { draft }
        await renderer.refine(first) { _ in XCTFail("refined twice"); return draft }

        await renderer.render(second) { draft }
        await renderer.refine(second) { _ in throw HairTryOn.Failure.segmenter }
        XCTAssertTrue(renderer.output(for: second)?.image === draft.image)
        XCTAssertTrue(renderer.refineFailed(second))
        XCTAssertNil(renderer.failure(for: second))
    }

    /// With the image model installed the draft is a stage of the work: nothing is handed out until the refined
    /// picture is there, and meanwhile the last finished picture of the photo stays up with a note of the progress.
    func testADraftThatIsNotShownWaitsForItsRefinedPicture() async throws {
        let renderer = TryOnRenderer(showsDrafts: false)
        let photo = UUID()
        let first = key("f1", photoID: photo), second = key("f2", photoID: photo), third = key("f3", photoID: photo)
        let draft = try output(), better = try output(), nextDraft = try output()
        await renderer.render(first) { draft }
        XCTAssertNil(renderer.output(for: first))
        XCTAssertNil(renderer.standIn(for: first))
        XCTAssertTrue(renderer.framedPhoto(for: first) === draft.original)
        await renderer.refine(first) { _ in
            renderer.report("画发丝", for: first)
            XCTAssertEqual(renderer.progress(for: first), "画发丝")
            XCTAssertNil(renderer.output(for: first))
            return better
        }
        XCTAssertTrue(renderer.output(for: first)?.image === better.image)
        XCTAssertNil(renderer.progress(for: first))

        // The next style: its draft is not shown either, the finished picture before it is.
        await renderer.render(second) { nextDraft }
        XCTAssertNil(renderer.output(for: second))
        XCTAssertTrue(renderer.standIn(for: second)?.image === better.image)
        // When the refined picture can't be made, the draft is all there is, and it is shown.
        await renderer.refine(second) { _ in throw HairTryOn.Failure.segmenter }
        XCTAssertTrue(renderer.output(for: second)?.image === nextDraft.image)
        XCTAssertTrue(renderer.refineFailed(second))

        // A note about work that is no longer on screen goes nowhere.
        await renderer.render(third) { draft }
        renderer.report("画发丝", for: second)
        XCTAssertNil(renderer.progress(for: second))
        XCTAssertNil(renderer.progress(for: third))
    }

    func testRefiningAnOldPreviewCannotTouchTheCurrentOne() async throws {
        let renderer = TryOnRenderer()
        let photo = UUID()
        let old = key("f1", photoID: photo), current = key("f2", photoID: photo)
        let oldDraft = try output(), better = try output(), currentDraft = try output()
        await renderer.render(old) { oldDraft }
        let waiting = expectation(description: "refine started")
        let gate = TestGate()
        let task = Task { @MainActor in
            await renderer.refine(old) { _ in waiting.fulfill(); await gate.wait(); return better }
        }
        await fulfillment(of: [waiting], timeout: 2)
        await renderer.render(current) { currentDraft }
        gate.open()
        await task.value

        XCTAssertTrue(renderer.output(for: current)?.image === currentDraft.image)
        XCTAssertTrue(renderer.output(for: old)?.image === oldDraft.image)
        XCTAssertFalse(renderer.isRefining(old))
    }

    func testSlowOldRenderCannotReplaceTheCurrentPreview() async throws {
        let renderer = TryOnRenderer()
        let photo = UUID()
        let old = key("f1", photoID: photo), current = key("f2", photoID: photo)
        let oldImage = try output(), currentImage = try output()
        let waiting = expectation(description: "old render started")
        let gate = TestGate()
        let task = Task { @MainActor in
            await renderer.render(old) { waiting.fulfill(); await gate.wait(); return oldImage }
        }
        await fulfillment(of: [waiting], timeout: 2)
        await renderer.render(current) { currentImage }
        gate.open()
        await task.value

        XCTAssertNil(renderer.output(for: old))
        XCTAssertTrue(renderer.output(for: current)?.image === currentImage.image)
        XCTAssertNil(renderer.failure(for: current))
    }

    func testCancelledFailureCannotOverwriteANewerResult() async throws {
        let renderer = TryOnRenderer()
        let photo = UUID()
        let old = key("f1", photoID: photo), current = key("f2", photoID: photo)
        let waiting = expectation(description: "render started")
        let gate = TestGate()
        let task = Task { @MainActor in
            await renderer.render(old) {
                waiting.fulfill(); await gate.wait(); throw HairTryOn.Failure.segmenter
            }
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        renderer.cancel()
        let image = try output()
        await renderer.render(current) { image }
        gate.open()
        await task.value
        XCTAssertNil(renderer.failure(for: current))
        XCTAssertNotNil(renderer.output(for: current))
    }

    func testCacheEvictsLeastRecentlyUsedPreviews() async throws {
        let renderer = TryOnRenderer(capacity: 2)
        let photo = UUID()
        let first = key("f1", photoID: photo), second = key("f2", photoID: photo), third = key("f3", photoID: photo)
        let image = try output()
        await renderer.render(first) { image }
        await renderer.render(second) { image }
        await renderer.render(first) { XCTFail("cached image should be reused"); return image }
        await renderer.render(third) { image }
        XCTAssertNotNil(renderer.output(for: first))
        XCTAssertNil(renderer.output(for: second))
        XCTAssertNotNil(renderer.output(for: third))
    }
}
