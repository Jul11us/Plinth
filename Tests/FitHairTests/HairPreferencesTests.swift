import XCTest
@testable import FitHair

final class HairPreferencesTests: XCTestCase {
    func testFiveMinuteBudgetIsRespectedWithoutPaddingTheResults() {
        let shapes = [ShapeScore(shape: .oval, probability: 1)]
        let preferences = HairPreferences(budget: .five)
        let styles = Hairstyle.pool(for: shapes, gender: .female, length: nil, preferences: preferences)
        XCTAssertFalse(styles.isEmpty)
        XCTAssertTrue(styles.allSatisfy { $0.hairProfile.minutes <= 5 })
        let none = Hairstyle.pool(for: shapes, gender: .female, length: .medium, onlyRecommended: true, preferences: preferences)
        XCTAssertTrue(none.isEmpty, "recommendation minimum must never bypass an explicit time limit")
    }

    func testFineSparseHairPrioritisesWeightAndExplainsHighLayers() throws {
        let bob = try XCTUnwrap(Hairstyle.all.first { $0.id == "f6" })
        let shag = try XCTUnwrap(Hairstyle.all.first { $0.id == "f11" })
        let preferences = HairPreferences(density: .sparse, strand: .fine)
        XCTAssertGreaterThan(bob.hairProfile.adjustment(for: preferences), shag.hairProfile.adjustment(for: preferences))
        XCTAssertTrue(shag.hairProfile.notes(for: preferences).contains { $0.contains("厚度") })
    }

    func testNaturalCurlAddsAStylingNoteForStraightCuts() throws {
        let straight = try XCTUnwrap(Hairstyle.all.first { $0.id == "f12" })
        let preferences = HairPreferences(texture: .curly)
        XCTAssertTrue(straight.hairProfile.notes(for: preferences).contains { $0.contains("额外吹整") })
        XCTAssertLessThan(straight.hairProfile.adjustment(for: preferences), 0)
    }

    func testUnspecifiedPreferencesPreserveTheOriginalOrder() {
        let shapes = [ShapeScore(shape: .round, probability: 1)]
        XCTAssertEqual(Hairstyle.pool(for: .round, gender: .female, length: nil),
                       Hairstyle.pool(for: shapes, gender: .female, length: nil, preferences: HairPreferences()))
    }

    func testPreferencesSavedBeforeTheCurrentHairFieldsStillLoad() throws {
        let old = #"{"density":"thick","strand":"any","texture":"wavy","budget":"ten"}"#
        let loaded = try JSONDecoder().decode(HairPreferences.self, from: Data(old.utf8))
        XCTAssertEqual(loaded.density, .thick)
        XCTAssertEqual(loaded.texture, .wavy)
        XCTAssertEqual(loaded.currentLength, .any)
    }

    func testCurrentHairOnlyDescribesAndNeverChangesTheRanking() {
        let onlyToday = HairPreferences(currentLength: .long, treatment: .dyed)
        XCTAssertFalse(onlyToday.isActive)
        XCTAssertEqual(onlyToday.currentHair, "长发 · 染过")
        XCTAssertNil(HairPreferences().currentHair)
    }
}
