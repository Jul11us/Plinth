import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FitHair

/// "Same person, ten photos": the bust photos are re-shot synthetically (scale, small rotation, shift,
/// brightness, JPEG re-compression) and the measured ratios must stay put.
final class RepeatabilityTests: XCTestCase {
    private func load(_ name: String) throws -> CGImage {
        let url = try XCTUnwrap(Res.url(name, "jpg"))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(AppState.uprightImage(from: src))
    }

    /// Deterministic pseudo-random variants of one photo.
    private func variants(of img: CGImage, count: Int, seed: UInt64) -> [CGImage] {
        var rng = SplitMix(seed: seed)
        return (0..<count).map { _ in
            let w = img.width, h = img.height
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.86, green: 0.855, blue: 0.84, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let scale = rng.uniform(0.85, 1.15)
            let angle = rng.uniform(-4, 4) * .pi / 180
            let tx = rng.uniform(-0.05, 0.05) * Double(w), ty = rng.uniform(-0.05, 0.05) * Double(h)
            ctx.translateBy(x: CGFloat(Double(w) / 2 + tx), y: CGFloat(Double(h) / 2 + ty))
            ctx.rotate(by: CGFloat(angle))
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let shifted = ctx.makeImage()!
            return jpegRoundTrip(shifted, quality: rng.uniform(0.55, 0.9), brightness: rng.uniform(-0.06, 0.06))
        }
    }

    private func jpegRoundTrip(_ img: CGImage, quality: Double, brightness: Double) -> CGImage {
        // brightness via a flat overlay, then JPEG encode/decode
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(brightness >= 0 ? CGColor(gray: 1, alpha: brightness) : CGColor(gray: 0, alpha: -brightness))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let src = CGImageSourceCreateWithData(data, nil)!
        return CGImageSourceCreateImageAtIndex(src, 0, nil)!
    }

    private func stats(_ v: [Double]) -> (mean: Double, sd: Double) {
        let m = v.reduce(0, +) / Double(v.count)
        return (m, (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot())
    }

    func testSamePersonTenPhotosGivesStableRatios() throws {
        for shape in [FaceShape.oval, .round, .heart, .oblong] {
            let shots = variants(of: try load(shape.imageName), count: 10, seed: 42)
            let ms = shots.compactMap { try? FaceAnalyzer.analyze($0) }
            XCTAssertGreaterThanOrEqual(ms.count, 9, "\(shape): face found in most shots")
            let lw = stats(ms.map(\.ratios.lengthToWidth)), fc = stats(ms.map(\.ratios.foreheadToCheek))
            let jc = stats(ms.map(\.ratios.jawToCheek)), ang = stats(ms.map(\.ratios.jawAngle))
            let verdicts = Set(ms.map { FaceShapeClassifier.classify($0.ratios).primary })
            for m in ms {
                let verdict = FaceShapeClassifier.classify(m)
                XCTAssertTrue(verdict.isUncertain || verdict.primary == shape,
                              "\(shape): a changed verdict must not be presented as certain")
                XCTAssertTrue(verdict.recommendationScores.contains { $0.shape == shape },
                              "\(shape): combined recommendations should retain the original shape, got \(verdict.candidateNames)")
            }
            print(String(format: "REPEAT %-8@ sd  L/W %.3f  F/C %.3f  J/C %.3f  angle %.2f°  verdicts %@",
                         shape.rawValue, lw.sd, fc.sd, jc.sd, ang.sd, verdicts.map(\.short).sorted().joined(separator: "/")))
            XCTAssertLessThan(lw.sd, 0.03, "\(shape) L/W too jumpy")
            XCTAssertLessThan(fc.sd, 0.03, "\(shape) F/C too jumpy")
            XCTAssertLessThan(jc.sd, 0.03, "\(shape) J/C too jumpy")
            XCTAssertLessThan(ang.sd, 3, "\(shape) jaw angle too jumpy")
        }
    }

    /// Different random variations from the ratio-spread test: uncertainty must remain honest.
    func testPerturbedReferencesNeverGiveACertainWrongVerdict() throws {
        for shape in FaceShape.allCases {
            let shots = variants(of: try load(shape.imageName), count: 8, seed: 97)
            let measurements = shots.compactMap { try? FaceAnalyzer.analyze($0) }
            XCTAssertGreaterThanOrEqual(measurements.count, 7)
            for measurement in measurements {
                let verdict = FaceShapeClassifier.classify(measurement)
                XCTAssertTrue(verdict.isUncertain || verdict.primary == shape,
                              "\(shape) became a certain \(verdict.primary)")
                XCTAssertTrue(verdict.recommendationScores.contains { $0.shape == shape },
                              "\(shape) missing from plausible recommendations: \(verdict.candidateNames)")
            }
        }
    }

    /// A burst usually contains one bad frame (head turning, blink, motion). The median must ignore it.
    func testMedianIgnoresOneBadFrame() throws {
        let base = try load(FaceShape.oval.imageName)
        var burst = variants(of: base, count: 9, seed: 7)
        let clean = try FaceAnalyzer.analyze(frames: burst).ratios.lengthToWidth
        // Bad frame: face squashed sideways by 18 %, as if the head turned mid-shot.
        let w = base.width, h = base.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.86, green: 0.855, blue: 0.84, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let sw = CGFloat(w) * 0.82
        ctx.draw(base, in: CGRect(x: (CGFloat(w) - sw) / 2, y: 0, width: sw, height: CGFloat(h)))
        let bad = ctx.makeImage()!
        let badAlone = try FaceAnalyzer.analyze(bad).ratios.lengthToWidth
        burst.append(bad)
        let m = try FaceAnalyzer.analyze(frames: burst)
        print(String(format: "MEDIAN L/W clean %.3f · bad frame alone %.3f · 10-frame median %.3f", clean, badAlone, m.ratios.lengthToWidth))
        XCTAssertGreaterThan(abs(badAlone - clean), 0.1, "the bad frame should really be off")
        XCTAssertLessThan(abs(m.ratios.lengthToWidth - clean), 0.02, "median should ignore the bad frame")
        XCTAssertEqual(m.sampleCount, 10)
        XCTAssertNotEqual(m.frameIndex, 9, "the displayed frame should not be the bad one")
        XCTAssertNotNil(m.spread)
    }

    func testJawCornerSitsBelowTheMouth() throws {
        for shape in FaceShape.allCases {
            let m = try FaceAnalyzer.analyze(try load(shape.imageName))
            let k = m.keyPoints
            XCTAssertGreaterThan(k.jawLeft.y, m.mouthCenter.y, "\(shape): left jaw corner above mouth")
            XCTAssertGreaterThan(k.jawRight.y, m.mouthCenter.y, "\(shape): right jaw corner above mouth")
            XCTAssertLessThan(k.jawLeft.y, k.chin.y)
            XCTAssertLessThan(k.jawRight.y, k.chin.y)
        }
    }
}

/// Small deterministic RNG so test runs are repeatable.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * Double(next() >> 11) / Double(1 << 53) }
}
