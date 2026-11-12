import XCTest
import AppKit
@testable import FitHair

final class ClassifierTests: XCTestCase {
    func testEachPrototypeClassifiesAsItself() {
        for shape in FaceShape.allCases {
            let result = FaceShapeClassifier.classify(shape.prototype)
            XCTAssertEqual(result.primary, shape, "\(shape) prototype should win")
            // The seven shapes overlap on this measuring scale, so a prototype wins clearly but not overwhelmingly.
            XCTAssertGreaterThan(result.probability(of: shape), 0.33)
        }
    }

    func testProbabilitiesSumToOne() {
        let r = FaceRatios(lengthToWidth: 1.38, foreheadToCheek: 0.99, jawToCheek: 0.76, jawAngle: 127)
        let total = FaceShapeClassifier.classify(r).scores.map(\.probability).reduce(0, +)
        XCTAssertEqual(total, 1, accuracy: 1e-9)
    }

    func testCloseCandidatesAreReportedAsUncertainAndRecommendedTogether() {
        let result = FaceShapeClassifier.classify(FaceShape.square.prototype)
        XCTAssertTrue(result.isUncertain)
        XCTAssertTrue(result.candidates.contains(.square))
        XCTAssertTrue(result.candidates.contains(.triangle))
        XCTAssertGreaterThan(result.recommendationScores.count, 1)
        XCTAssertEqual(result.recommendationScores.map(\.probability).reduce(0, +), 1, accuracy: 1e-9)
    }

    func testOutOfReferenceMeasurementsDoNotBecomeCertainFromSoftmaxAlone() {
        let unusual = FaceRatios(lengthToWidth: 2.2, foreheadToCheek: 0.6, jawToCheek: 0.5, jawAngle: 160)
        let result = FaceShapeClassifier.classify(unusual)
        XCTAssertTrue(result.isUncertain)
        XCTAssertTrue(result.needsRetake)
        let invalid = FaceShapeClassifier.classify(FaceRatios(lengthToWidth: .nan, foreheadToCheek: 1, jawToCheek: 1, jawAngle: 130))
        XCTAssertTrue(invalid.needsRetake)
        XCTAssertTrue(invalid.scores.allSatisfy { $0.probability.isFinite })
    }

    func testBlendBetweenOvalAndHeartShowsSecondary() {
        // Halfway between the oval and heart prototypes: neither should win outright, and both should be
        // among the likeliest answers (the diamond prototype sits between them on the calibrated scale).
        let o = FaceShape.oval.prototype, h = FaceShape.heart.prototype
        let mid = FaceRatios(lengthToWidth: (o.lengthToWidth + h.lengthToWidth) / 2,
                             foreheadToCheek: (o.foreheadToCheek + h.foreheadToCheek) / 2,
                             jawToCheek: (o.jawToCheek + h.jawToCheek) / 2,
                             jawAngle: (o.jawAngle + h.jawAngle) / 2)
        let result = FaceShapeClassifier.classify(mid)
        let top3 = Set(result.scores.prefix(3).map(\.shape))
        XCTAssertTrue(top3.contains(.oval) && top3.contains(.heart), "top 3 was \(result.scores.prefix(3).map(\.shape))")
        XCTAssertNotNil(result.secondary)
    }

    func testPoolIsSortedBestFirstAndFiltered() {
        let pool = Hairstyle.pool(for: .round, gender: .female, length: nil)
        XCTAssertEqual(pool.count, Hairstyle.all.filter { $0.gender == .female }.count)
        XCTAssertTrue(pool.allSatisfy { $0.gender == .female })
        XCTAssertEqual(pool.map { $0.score(for: .round) }, pool.map { $0.score(for: .round) }.sorted(by: >))
        let maleShort = Hairstyle.pool(for: .oval, gender: .male, length: .short)
        XCTAssertEqual(maleShort.count, Hairstyle.all.filter { $0.gender == .male && $0.length == .short }.count)
    }

    func testRecommendedPoolHidesPoorFitsButNeverGoesEmpty() {
        for shape in FaceShape.allCases {
            for gender in Gender.allCases {
                for length in [nil] + HairLength.allCases.map(Optional.some) {
                    let rec = Hairstyle.pool(for: shape, gender: gender, length: length, onlyRecommended: true)
                    let all = Hairstyle.pool(for: shape, gender: gender, length: length)
                    XCTAssertFalse(rec.isEmpty, "\(shape) \(gender) \(String(describing: length)): empty")
                    XCTAssertEqual(rec, Array(all.prefix(rec.count)), "recommended must be the best of the full list")
                    if rec.count > Hairstyle.recommendedMinCount {
                        XCTAssertTrue(rec.allSatisfy { $0.score(for: shape) >= Hairstyle.recommendedMinScore })
                    }
                }
            }
        }
    }
}

final class AnalyzerTests: XCTestCase {
    private func cgImage(_ name: String) throws -> CGImage {
        let url = try XCTUnwrap(Res.url(name, "jpg"), "missing resource \(name)")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(AppState.uprightImage(from: src))
    }

    func testMeasuresBundledBusts() throws {
        for shape in FaceShape.allCases {
            let m = try FaceAnalyzer.analyze(try cgImage(shape.imageName))
            XCTAssertGreaterThan(m.allPoints.count, 60, "\(shape): landmarks")
            XCTAssert((0.9...2.0).contains(m.ratios.lengthToWidth), "\(shape): L/W \(m.ratios.lengthToWidth)")
            XCTAssert((0.6...1.3).contains(m.ratios.foreheadToCheek), "\(shape): F/C \(m.ratios.foreheadToCheek)")
            XCTAssert((0.5...1.2).contains(m.ratios.jawToCheek), "\(shape): J/C \(m.ratios.jawToCheek)")
            XCTAssert((90...175).contains(m.ratios.jawAngle), "\(shape): angle \(m.ratios.jawAngle)")
            let k = m.keyPoints
            XCTAssertLessThan(k.hairline.y, k.chin.y)
            XCTAssertLessThan(k.cheekLeft.x, k.cheekRight.x)
            let c = FaceShapeClassifier.classify(m.ratios)
            print(String(format: "BUST %-8@ L/W %.2f F/C %.2f J/C %.2f angle %5.1f → %@ %d%%",
                         shape.rawValue, m.ratios.lengthToWidth, m.ratios.foreheadToCheek, m.ratios.jawToCheek,
                         m.ratios.jawAngle, c.primary.rawValue, c.scores[0].percent))
        }
    }

    /// The seven reference busts are what the home page shows; each must come out as its own shape.
    func testBustsClassifyAsThemselves() throws {
        for shape in FaceShape.allCases {
            let m = try FaceAnalyzer.analyze(try cgImage(shape.imageName))
            let c = FaceShapeClassifier.classify(m.ratios)
            XCTAssertEqual(c.primary, shape, "\(shape) bust classified as \(c.primary), scores \(c.scores.prefix(3).map { "\($0.shape.rawValue) \($0.percent)%" })")
        }
    }

    func testHairlineAndForeheadAreMeasuredOnBusts() throws {
        XCTAssertTrue(HairSegmenter.isAvailable, "hair segmentation model missing from resources")
        for shape in FaceShape.allCases {
            let m = try FaceAnalyzer.analyze(try cgImage(shape.imageName))
            XCTAssertTrue(m.hairlineMeasured, "\(shape): hairline fell back to the estimate")
            XCTAssertTrue(m.foreheadMeasured, "\(shape): forehead fell back to the estimate")
            XCTAssertFalse(m.foreheadCovered, "\(shape): forehead reported as covered")
            let k = m.keyPoints
            let eyeY = (k.pupilLeft.y + k.pupilRight.y) / 2
            XCTAssertLessThan(k.hairline.y, eyeY - (k.chin.y - eyeY) * 0.5, "\(shape): hairline too low")
            XCTAssertGreaterThan(k.hairline.y, 0, "\(shape): hairline off the image")
            XCTAssertLessThan(k.foreheadLeft.x, k.pupilLeft.x, "\(shape): forehead edge inside the eye")
            XCTAssertGreaterThan(k.foreheadRight.x, k.pupilRight.x, "\(shape): forehead edge inside the eye")
        }
    }

    func testBlankImageHasNoFace() throws {
        let ctx = CGContext(data: nil, width: 200, height: 250, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.86, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 250))
        XCTAssertThrowsError(try FaceAnalyzer.analyze(ctx.makeImage()!)) { error in
            XCTAssertEqual(error as? FaceAnalysisError, .noFace)
        }
    }
}
