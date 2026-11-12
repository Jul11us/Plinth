import XCTest
@testable import FitHair

final class HairWordTests: XCTestCase {
    func testEveryLetterIsCombedWithStrandsThatStayNearTheWord() {
        let word = HairWord.make()
        XCTAssertFalse(word.glyphBounds.isEmpty)
        for glyph in word.glyphBounds.indices {
            XCTAssertGreaterThan(word.strands.filter { $0.glyph == glyph }.count, 40, "letter \(glyph) has too little hair")
        }
        // Stray hairs may leave the letters, but must fit the margin the images are baked with.
        let area = CGRect(origin: .zero, size: word.size).insetBy(dx: -HairWordArt.pad, dy: -HairWordArt.pad)
        for strand in word.strands {
            XCTAssertTrue((0...1).contains(strand.arrival))
            XCTAssertTrue(strand.points.allSatisfy { area.contains($0) })
        }
    }

    func testSameWordOnEveryLaunch() {
        let a = HairWord.make(), b = HairWord.make()
        XCTAssertEqual(a.strands.count, b.strands.count)
        XCTAssertEqual(a.strands.first?.points, b.strands.first?.points)
    }
}
