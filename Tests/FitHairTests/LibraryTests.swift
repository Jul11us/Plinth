import XCTest
@testable import FitHair

/// The hairstyle library in Resources/hairstyles.json.
final class LibraryTests: XCTestCase {
    func testLibraryLoadsAndIsComplete() {
        let all = Hairstyle.all
        XCTAssertEqual(all.count, 24)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "duplicate ids")
        XCTAssertEqual(Hairstyle.specLabels.count, 6)
        for s in all {
            XCTAssertEqual(s.specs.count, 6, "\(s.id) specs")
            XCTAssertEqual(s.scores.count, 7, "\(s.id) needs a score for every face shape")
            XCTAssertEqual(s.why.count, 3, "\(s.id) why")
            XCTAssertEqual(s.avoid.count, 2, "\(s.id) avoid")
            XCTAssertFalse(s.say.isEmpty, "\(s.id) say")
            XCTAssertFalse(s.prompt.isEmpty, "\(s.id) prompt")
            XCTAssertTrue(s.scores.values.allSatisfy { (0...100).contains($0) }, "\(s.id) score range")
            XCTAssertGreaterThan(s.hairProfile.minutes, 0, "\(s.id) care time")
            XCTAssertTrue(s.care.contains("\(s.hairProfile.minutes) 分钟"), "\(s.id) care metadata must match the displayed instructions")
        }
        for gender in Gender.allCases {
            XCTAssertEqual(all.filter { $0.gender == gender }.count, 12, "\(gender)")
        }
    }

    /// Different face shapes should get different first recommendations, or the "by face shape" promise is empty.
    func testFaceShapesGetDifferentTopPicks() {
        for gender in Gender.allCases {
            let tops = Set(FaceShape.allCases.compactMap { Hairstyle.pool(for: $0, gender: gender, length: nil).first?.id })
            XCTAssertGreaterThanOrEqual(tops.count, 5, "\(gender): only \(tops.count) distinct #1 styles across 7 shapes")
        }
    }

    /// The ten original styles ship with bust photos; new ones may still be waiting for theirs.
    func testOriginalStylesHavePhotos() {
        for style in Hairstyle.all {
            XCTAssertTrue(Res.hasImage(style.imageName), "\(style.imageName).jpg missing")
        }
    }
}
