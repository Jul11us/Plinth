import XCTest
import ImageIO
@testable import FitHair

@MainActor
final class AppStateTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "PlinthTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testGenderIsAskedOnlyUntilChosen() {
        let first = AppState(defaults: defaults)
        XCTAssertFalse(first.genderChosen)
        first.showStyles(for: .male)
        XCTAssertTrue(first.genderChosen)
        XCTAssertEqual(first.gender, .male)
        XCTAssertEqual(first.route, .pool)
        let relaunched = AppState(defaults: defaults)
        XCTAssertTrue(relaunched.genderChosen)
        XCTAssertEqual(relaunched.gender, .male)
    }

    private func bustResult() throws -> (FaceMeasurement, CGImage) {
        let url = try XCTUnwrap(Res.url("shape-oval", "jpg"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(AppState.uprightImage(from: source))
        return (try FaceAnalyzer.analyze(image), image)
    }

    private func temporaryStore() -> LastResultStore {
        let store = LastResultStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PlinthTests-\(UUID().uuidString)"))
        addTeardownBlock { store.clear() }
        return store
    }

    func testLastResultComesBackAfterRelaunchAndCanBeDeleted() async throws {
        let (measurement, image) = try bustResult()
        let store = temporaryStore()
        let shade = HairTryOn.Shade.all[2]
        store.save(LastResult(measurement: measurement, colourProfile: ColourProfile(undertone: .warm, depth: .light, hairLevel: 3),
                              shape: .heart, shapeConfirmed: true, fromCamera: true, shadeID: shade.id), photo: image)

        let state = AppState(defaults: defaults, lastResult: store)
        XCTAssertEqual(state.savedResultShape, .heart)
        XCTAssertNil(state.photo)

        state.resumeLastResult()
        XCTAssertEqual(state.route, .result)
        XCTAssertEqual(state.measurement, measurement)
        XCTAssertEqual(state.shape, .heart)
        XCTAssertTrue(state.shapeConfirmed)
        XCTAssertNotNil(state.classification)
        XCTAssertEqual(state.photo?.width, image.width)
        XCTAssertEqual(state.photoSource, .camera)
        XCTAssertEqual(state.hairShade.id, shade.id)
        XCTAssertEqual(state.colourProfile?.hairLevel, 3)

        state.forgetLastResult()
        await state.pendingSave?.value
        XCTAssertNil(state.savedResultShape)
        XCTAssertNil(store.load())
        XCTAssertNil(AppState(defaults: defaults, lastResult: store).savedResultShape)
    }

    func testChangingTheShapeUpdatesTheSavedResultButKeepsThePhoto() async throws {
        let (measurement, image) = try bustResult()
        let store = temporaryStore()
        store.save(LastResult(measurement: measurement, colourProfile: nil, shape: .oval, shapeConfirmed: false, fromCamera: false, shadeID: "auto"), photo: image)
        let state = AppState(defaults: defaults, lastResult: store)
        state.resumeLastResult()
        state.chooseShape(.square)
        await state.pendingSave?.value
        XCTAssertEqual(store.load()?.shape, .square)
        XCTAssertEqual(store.load()?.shapeConfirmed, true)
        XCTAssertNotNil(store.loadPhoto(matching: measurement.imageSize))
    }

    func testDamagedSavedResultIsDropped() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.directory.appendingPathComponent("result.json"))
        let state = AppState(defaults: defaults, lastResult: store)
        XCTAssertNil(state.savedResultShape)
        state.resumeLastResult()
        XCTAssertEqual(state.route, .home)
    }

    func testStartingOverKeepsSavedStylesAcrossRelaunches() {
        let state = AppState(defaults: defaults)
        state.toggleSaved("f1")
        state.toggleSaved("m2")
        state.hairShade = HairTryOn.Shade.all[2]
        state.lengthFilter = .long
        let oldPhoto = state.photoID

        state.startOver()

        XCTAssertEqual(state.savedStyleIDs, ["f1", "m2"])
        XCTAssertEqual(AppState(defaults: defaults).savedStyleIDs, ["f1", "m2"])
        XCTAssertEqual(state.route, .home)
        XCTAssertNil(state.photo)
        XCTAssertNil(state.classification)
        XCTAssertNil(state.lengthFilter)
        XCTAssertEqual(state.hairShade, .auto)
        XCTAssertNotEqual(state.photoID, oldPhoto)
    }

    func testEmptySavedFilterNeverShowsAStyleFromAnotherGender() {
        let state = AppState(defaults: defaults)
        state.gender = .female
        state.savedStyleIDs = ["f1"]
        state.scope = .saved
        state.selectedStyleID = "f1"
        XCTAssertEqual(state.poolSelection?.id, "f1")

        state.gender = .male
        // The detail is safe before SwiftUI's onChange has had a chance to synchronise selection.
        XCTAssertTrue(state.pool.isEmpty)
        XCTAssertNil(state.poolSelection)
        state.synchronizePoolSelection()
        XCTAssertEqual(state.selectedStyleID, "")

        state.gender = .female
        state.synchronizePoolSelection()
        XCTAssertEqual(state.poolSelection?.id, "f1")
    }

    func testRemovingASelectedFavouriteMovesTheDetailToTheRemainingStyle() {
        let state = AppState(defaults: defaults)
        state.gender = .female
        state.savedStyleIDs = ["f1", "f3"]
        state.scope = .saved
        state.selectedStyleID = "f1"

        state.toggleSaved("f1")
        XCTAssertEqual(state.poolSelection?.id, "f3")
        state.synchronizePoolSelection()
        XCTAssertEqual(state.selectedStyleID, "f3")

        state.toggleSaved("f3")
        XCTAssertNil(state.poolSelection)
    }

    func testManualConfirmationUsesOneShapeEvenWhenConfirmingTheTopCandidate() throws {
        let state = AppState(defaults: defaults)
        let classification = FaceShapeClassifier.classify(FaceShape.square.prototype)
        XCTAssertTrue(classification.isUncertain)
        state.classification = classification
        state.shape = classification.primary
        XCTAssertTrue(state.usesMixedRecommendations)
        XCTAssertGreaterThan(state.recommendationScores.count, 1)
        XCTAssertTrue(state.faceSummary.contains("待确认"))

        state.chooseShape(classification.primary)

        XCTAssertFalse(state.usesMixedRecommendations)
        XCTAssertEqual(state.recommendationScores, [.init(shape: .square, probability: 1)])
        XCTAssertFalse(state.faceSummary.contains("待确认"))
    }

    func testHairPreferencesPersistAndTimeFilterCanBeEmpty() {
        let state = AppState(defaults: defaults)
        state.gender = .female
        state.scope = .all
        state.lengthFilter = .medium
        state.hairPreferences = .init(density: .sparse, strand: .fine, texture: .curly, budget: .five)
        XCTAssertTrue(state.pool.isEmpty)
        XCTAssertNil(state.poolSelection)
        XCTAssertEqual(AppState(defaults: defaults).hairPreferences, state.hairPreferences)

        state.hairPreferences.budget = .ten
        XCTAssertFalse(state.pool.isEmpty)
        XCTAssertTrue(state.pool.allSatisfy { $0.hairProfile.minutes <= 10 })
    }
}
