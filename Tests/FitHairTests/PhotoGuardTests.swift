import XCTest
@testable import FitHair

/// Photos the app can't measure properly must say so instead of giving a confident verdict.
final class PhotoGuardTests: XCTestCase {
    private func bust() throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(Res.url("shape-oval", "jpg")) as CFURL, nil))
        return try XCTUnwrap(AppState.uprightImage(from: source))
    }

    private func redraw(_ image: CGImage, width: Int, height: Int, _ place: (CGContext) -> Void) throws -> CGImage {
        let c = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(gray: 0.8, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        place(c)
        return try XCTUnwrap(c.makeImage())
    }

    private func rotated(by degrees: Double) throws -> CGImage {
        let image = try bust()
        return try redraw(image, width: 1000, height: 1000) { c in
            c.translateBy(x: 500, y: 500); c.rotate(by: degrees * .pi / 180)
            c.draw(image, in: CGRect(x: -300, y: -375, width: 600, height: 750))
        }
    }

    func testTinyFaceNeedsARetake() throws {
        let image = try bust()
        let small = try redraw(image, width: 120, height: 150) { $0.draw(image, in: CGRect(x: 0, y: 0, width: 120, height: 150)) }
        let m = try FaceAnalyzer.analyze(small)
        XCTAssertTrue(m.faceTooSmall)
        XCTAssertTrue(FaceShapeClassifier.classify(m).needsRetake)
    }

    func testChinOutOfFrameNeedsARetake() throws {
        let image = try bust()
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: image.height * 52 / 100)))
        let m = try FaceAnalyzer.analyze(cropped)
        XCTAssertTrue(m.faceCutOff)
        XCTAssertTrue(FaceShapeClassifier.classify(m).needsRetake)
    }

    func testUpsideDownPhotoIsRefused() throws {
        XCTAssertThrowsError(try FaceAnalyzer.analyze(try rotated(by: 180))) {
            XCTAssertEqual($0 as? FaceAnalysisError, .upsideDown)
        }
    }

    func testHeavilyTiltedHeadNeedsARetake() throws {
        let m = try FaceAnalyzer.analyze(try rotated(by: 35))
        XCTAssertTrue(m.tiltedTooFar)
        XCTAssertTrue(FaceShapeClassifier.classify(m).needsRetake)
    }

    func testAnOrdinaryPhotoPassesEveryCheck() throws {
        let m = try FaceAnalyzer.analyze(try bust())
        XCTAssertFalse(m.faceTooSmall)
        XCTAssertFalse(m.faceCutOff)
        XCTAssertFalse(m.tiltedTooFar)
        XCTAssertFalse(FaceShapeClassifier.classify(m).needsRetake)
    }
}
