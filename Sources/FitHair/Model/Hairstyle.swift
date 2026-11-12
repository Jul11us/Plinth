import Foundation

enum Gender: String, CaseIterable, Identifiable, Codable {
    case female, male
    var id: String { rawValue }
    var label: String { self == .female ? "女生" : "男生" }
}

enum BustAngle: String, CaseIterable, Identifiable {
    case front = "正面", side = "侧面", back = "背面"
    var id: String { rawValue }
}

enum HairLength: String, CaseIterable, Identifiable, Codable {
    case short, medium, long
    var id: String { rawValue }
    var label: String {
        switch self {
        case .short: "短发"
        case .medium: "中长发"
        case .long: "长发"
        }
    }
}

/// One hairstyle from `Resources/hairstyles.json`. Adding a style means adding a record there plus a
/// bust photo `hair-<id>.jpg` (the record's `prompt` is the hairstyle part of the image prompt;
/// `scripts/hairstyle-prompts.py` prints the full prompts for styles that still have no photo).
struct Hairstyle: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let gender: Gender
    let length: HairLength
    let ease: String
    let care: String
    let cycle: String
    let why: [String]
    /// One sentence to say to the barber.
    let say: String
    /// 长度 / 层次 / 刘海 / 两侧·后颈 / 发尾·质感 / 分线·造型
    let specs: [String]
    let avoid: [String]
    /// Suitability 0–100 per face shape.
    let scores: [FaceShape: Int]
    /// English description of the hairstyle for the bust-image prompt.
    let prompt: String
    /// What the bust that was made from `prompt` actually looks like, in the same kind of words, for the few
    /// where the try-on would otherwise draw something else: a quiff "brushed up and back" comes out slicked back,
    /// while its bust stands up in spikes.
    var look: String? = nil
    /// The description the try-on paints the hair from.
    var tryOnPrompt: String { look ?? prompt }
    let hairProfile: HairCareProfile

    /// For a cut whose faded sides show from the front, how far above the eyes the hair is back to full length, in
    /// eye-distances; nil when the sides are not clipped. Read from the description the try-on paints from: a
    /// high fade ends at the temples, a low one just above the ears. A cut whose top hangs over its fade, so that
    /// the bust shows none, says so by leaving the fade out of its `look`.
    var fadeHeight: Double? {
        let words = tryOnPrompt
        guard words.contains("fade") else { return nil }
        if words.range(of: "high[a-z ]*fade", options: .regularExpression) != nil { return 1.05 }
        if words.range(of: "low[a-z ]*fade", options: .regularExpression) != nil { return 0.45 }
        return 0.75
    }

    var imageName: String { "hair-\(id)" }
    var trimCycle: TrimCycle? { TrimCycle(cycle) }

    func imageName(for angle: BustAngle) -> String {
        switch angle {
        case .front: imageName
        case .side: sideImageName
        case .back: backImageName
        }
    }

    var sideImageName: String { "hair-\(id)-side" }
    var backImageName: String { "hair-\(id)-back" }
    /// The barber card shows three angles when a style has them, otherwise just the front.
    var hasAllViews: Bool { Res.hasImage(sideImageName) && Res.hasImage(backImageName) }
    func score(for shape: FaceShape) -> Int { scores[shape] ?? 0 }
    func score(for shapes: [ShapeScore]) -> Int {
        Int(shapes.reduce(0) { $0 + Double(score(for: $1.shape)) * $1.probability }.rounded())
    }

    static let specLabels: [String] = library.specLabels
    static let all: [Hairstyle] = library.styles

    /// A style scoring under this for a face shape is only shown when the user asks to see everything…
    static let recommendedMinScore = 80
    /// …but the recommended list never has fewer than this many styles.
    static let recommendedMinCount = 3
    /// …and no more than this many, or "recommended" stops meaning anything: most of the library scores 80+.
    static let recommendedMaxCount = 6

    /// Styles for a face shape and gender, best first. `onlyRecommended` hides the poor fits.
    static func pool(for shape: FaceShape, gender: Gender, length: HairLength?, onlyRecommended: Bool = false) -> [Hairstyle] {
        pool(for: [.init(shape: shape, probability: 1)], gender: gender, length: length, onlyRecommended: onlyRecommended)
    }

    static func pool(for shapes: [ShapeScore], gender: Gender, length: HairLength?, onlyRecommended: Bool = false,
                     preferences: HairPreferences = HairPreferences()) -> [Hairstyle] {
        let sorted = all.filter { $0.gender == gender && (length == nil || $0.length == length) && $0.hairProfile.fitsTime(preferences) }
            .sorted { a, b in
                let sa = a.score(for: shapes) + a.hairProfile.adjustment(for: preferences)
                let sb = b.score(for: shapes) + b.hairProfile.adjustment(for: preferences)
                return sa != sb ? sa > sb : a.id < b.id
            }
        guard onlyRecommended else { return sorted }
        // With two possible shapes, a style has to suit both; the average would let nearly everything through.
        let good = sorted.filter { style in shapes.allSatisfy { style.score(for: $0.shape) >= recommendedMinScore } }
        return good.count >= recommendedMinCount ? Array(good.prefix(recommendedMaxCount)) : Array(sorted.prefix(recommendedMinCount))
    }
}

/// Lets `[FaceShape: Int]` decode from a JSON object keyed by the shape names.
extension FaceShape: CodingKeyRepresentable {}

private struct Library: Codable {
    let specLabels: [String]
    let styles: [Hairstyle]
}

private let library: Library = {
    guard let url = Res.url("hairstyles", "json"),
          let data = try? Data(contentsOf: url) else {
        assertionFailure("hairstyles.json missing from resources")
        return Library(specLabels: [], styles: [])
    }
    do { return try JSONDecoder().decode(Library.self, from: data) }
    catch {
        assertionFailure("hairstyles.json: \(error)")
        return Library(specLabels: [], styles: [])
    }
}()
