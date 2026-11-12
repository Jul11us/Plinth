import XCTest
@testable import FitHair

final class ColourAdvisorTests: XCTestCase {
    private func skin(_ r: Float, _ g: Float, _ b: Float) -> [SIMD3<Float>] {
        Array(repeating: SIMD3(r / 255, g / 255, b / 255), count: 500)
    }

    func testReadsUndertoneAndDepth() {
        XCTAssertEqual(ColourAdvisor.readSkin(skin(225, 180, 140)).0, .warm)
        XCTAssertEqual(ColourAdvisor.readSkin(skin(235, 190, 180)).0, .cool)
        XCTAssertEqual(ColourAdvisor.readSkin(skin(225, 180, 140)).1, .light)
        XCTAssertEqual(ColourAdvisor.readSkin(skin(110, 75, 50)).1, .deep)
    }

    func testPlasterShowsNoSkinColour() {
        let (undertone, depth) = ColourAdvisor.readSkin(skin(203, 199, 196))
        XCTAssertNil(undertone)
        XCTAssertNil(depth)
        XCTAssertTrue(ColourAdvisor.suggestions(for: ColourProfile()).isEmpty)
    }

    func testSuggestionsFollowTheUndertone() {
        let warm = ColourAdvisor.suggestions(for: ColourProfile(undertone: .warm, depth: .medium, hairLevel: 3))
        let cool = ColourAdvisor.suggestions(for: ColourProfile(undertone: .cool, depth: .medium, hairLevel: 3))
        XCTAssertEqual(warm.count, 3)
        XCTAssertTrue(warm.allSatisfy { $0.warmth != .cool })
        XCTAssertTrue(cool.allSatisfy { $0.warmth != .warm })
        // Very light colours aren't suggested against deep skin.
        let deep = ColourAdvisor.suggestions(for: ColourProfile(undertone: .warm, depth: .deep, hairLevel: 3))
        XCTAssertTrue(deep.allSatisfy { ($0.level ?? 0) < 8 })
    }

    /// A dye is a swatch, the colourist's numbers, and the words the image model draws it from.
    func testEveryDyeIsComplete() {
        let dyes = HairTryOn.Shade.all.filter { $0.hex != nil }
        XCTAssertEqual(Set(HairTryOn.Shade.all.map(\.id)).count, HairTryOn.Shade.all.count)
        XCTAssertEqual(Set(dyes.map(\.name)).count, dyes.count)
        for dye in dyes {
            XCTAssertNotNil(dye.promptName, dye.id)
            XCTAssertNotNil(dye.level, dye.id)
            // No colour shows on hair darker than itself.
            XCTAssertGreaterThanOrEqual(dye.base ?? 0, dye.level ?? 99, dye.id)
        }
        XCTAssertNil(HairTryOn.Shade.auto.promptName)
        // The swatches of a family sit in one row of the try-on panel.
        for family in HairTryOn.Shade.Family.allCases {
            XCTAssertLessThanOrEqual(HairTryOn.Shade.all.filter { $0.family == family }.count, 6, family.rawValue)
        }
    }

    func testBleachingFollowsTheLift() {
        XCTAssertEqual(ColourAdvisor.bleach(toBase: 4, from: 4), "比现在深或差不多，不用漂")
        XCTAssertEqual(ColourAdvisor.bleach(toBase: 6, from: 3), "不用漂，直接染")
        XCTAssertEqual(ColourAdvisor.bleach(toBase: 8, from: 2), "要先漂 1–2 次")
        XCTAssertEqual(ColourAdvisor.bleach(toBase: 10, from: 2), "要先漂 2 次以上")
    }

    func testCardOnlyMentionsAChosenColour() {
        XCTAssertTrue(ColourAdvisor.cardRows(shade: .auto, profile: nil).isEmpty)
        let milkTea = HairTryOn.Shade.all.first { $0.id == "milktea" }!
        let rows = ColourAdvisor.cardRows(shade: milkTea, profile: ColourProfile(hairLevel: 2))
        XCTAssertEqual(rows.map(\.0), ["发色", "打底"])
        XCTAssertTrue(rows[1].1.contains("漂"))
    }
}
