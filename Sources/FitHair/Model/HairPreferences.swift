import Foundation

/// Preferences supplied by the user; the app does not infer hair density or texture from a selfie.
struct HairPreferences: Equatable, Codable {
    enum Density: String, CaseIterable, Identifiable, Codable {
        case any, sparse, normal, thick
        var id: String { rawValue }
        var label: String {
            switch self { case .any: "不限定"; case .sparse: "偏少"; case .normal: "适中"; case .thick: "偏多" }
        }
    }
    enum Strand: String, CaseIterable, Identifiable, Codable {
        case any, fine, normal, coarse
        var id: String { rawValue }
        var label: String {
            switch self { case .any: "不限定"; case .fine: "细软"; case .normal: "适中"; case .coarse: "粗硬" }
        }
    }
    enum Texture: String, CaseIterable, Identifiable, Codable {
        case any, straight, wavy, curly
        var id: String { rawValue }
        var label: String {
            switch self { case .any: "不限定"; case .straight: "直发"; case .wavy: "微卷"; case .curly: "自然卷" }
        }
    }
    enum Budget: String, CaseIterable, Identifiable, Codable {
        case any, five, ten, fifteen
        var id: String { rawValue }
        var minutes: Int? {
            switch self { case .any: nil; case .five: 5; case .ten: 10; case .fifteen: 15 }
        }
        var label: String { minutes.map { "\($0) 分钟以内" } ?? "不限定" }
    }

    /// What the hair is like today. For the hairdresser only; it doesn't change which styles are recommended.
    enum CurrentLength: String, CaseIterable, Identifiable, Codable {
        case any, short, medium, long
        var id: String { rawValue }
        var label: String {
            switch self { case .any: "不限定"; case .short: "短发"; case .medium: "中长发"; case .long: "长发" }
        }
    }
    enum Treatment: String, CaseIterable, Identifiable, Codable {
        case any, none, dyed, permed, both
        var id: String { rawValue }
        var label: String {
            switch self { case .any: "不限定"; case .none: "没有烫染过"; case .dyed: "染过"; case .permed: "烫过"; case .both: "烫染都做过" }
        }
    }

    var density: Density = .any
    var strand: Strand = .any
    var texture: Texture = .any
    var budget: Budget = .any
    var currentLength: CurrentLength = .any
    var treatment: Treatment = .any
    /// Set when anything here changes the order of the recommendations.
    var isActive: Bool { density != .any || strand != .any || texture != .any || budget != .any }
    /// The hair as it is now, for the barber card; nil when none of it has been filled in.
    var currentHair: String? {
        let parts = [currentLength == .any ? nil : currentLength.label,
                     density == .any ? nil : "发量\(density.label)",
                     strand == .any ? nil : strand.label + "发丝",
                     texture == .any ? nil : texture.label,
                     treatment == .any ? nil : treatment.label].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var summary: String {
        [density == .any ? nil : "发量\(density.label)",
         strand == .any ? nil : strand.label + "发丝",
         texture == .any ? nil : texture.label,
         budget == .any ? nil : "每天\(budget.label)"].compactMap { $0 }.joined(separator: " · ")
    }
}

extension HairPreferences {
    /// Preferences saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        density = try c.decodeIfPresent(Density.self, forKey: .density) ?? .any
        strand = try c.decodeIfPresent(Strand.self, forKey: .strand) ?? .any
        texture = try c.decodeIfPresent(Texture.self, forKey: .texture) ?? .any
        budget = try c.decodeIfPresent(Budget.self, forKey: .budget) ?? .any
        currentLength = try c.decodeIfPresent(CurrentLength.self, forKey: .currentLength) ?? .any
        treatment = try c.decodeIfPresent(Treatment.self, forKey: .treatment) ?? .any
    }
}

/// Editable library metadata describing the pictured finish and the care instructions for each cut.
struct HairCareProfile: Hashable, Codable {
    enum Finish: String, Codable { case cropped, straight, wavy, curly }
    enum Layers: String, Codable { case minimal, light, high }
    let minutes: Int
    let finish: Finish
    let layers: Layers
    let addsVolume: Bool
    let keepsWeight: Bool
    let supportsTryOn: Bool

    func fitsTime(_ preferences: HairPreferences) -> Bool {
        preferences.budget.minutes.map { minutes <= $0 } ?? true
    }

    /// Small, explicit preference adjustments to the face-shape score, not a salon assessment.
    func adjustment(for preferences: HairPreferences) -> Int {
        var value = 0
        if preferences.density == .sparse { value += (keepsWeight ? 4 : -4) + (addsVolume ? 2 : 0) }
        if preferences.density == .thick { value += layers == .high ? 3 : (layers == .minimal ? -3 : 0) }
        if preferences.strand == .fine { value += keepsWeight ? 2 : -2 }
        if preferences.strand == .coarse && addsVolume { value -= 3 }
        switch (preferences.texture, finish) {
        case (.straight, .wavy), (.straight, .curly): value -= 4
        case (.wavy, .straight): value -= 3
        case (.curly, .straight): value -= 8
        case (.curly, .wavy): value -= 4
        default: break
        }
        return value
    }

    func notes(for preferences: HairPreferences) -> [String] {
        var notes: [String] = []
        if preferences.density == .sparse && !keepsWeight {
            notes.append("发量偏少，建议请理发师保留厚度，层次不要打得太碎。")
        }
        if preferences.strand == .fine && addsVolume {
            notes.append("细软发想保持图里的蓬松度，可能需要吹整或定型。")
        }
        if preferences.strand == .coarse && addsVolume {
            notes.append("粗硬发做蓬松造型时，先确认两侧的量感是否容易控制。")
        }
        switch (preferences.texture, finish) {
        case (.straight, .wavy), (.straight, .curly):
            notes.append("图里的卷度需要烫发或日常造型，单靠剪发不一定能达到。")
        case (.wavy, .straight), (.curly, .straight):
            notes.append("想接近图里的直发效果，可能需要拉直或额外吹整。")
        case (.curly, .wavy):
            notes.append("自然卷的卷径可能和图里不同，先和理发师确认卷度与收缩后的长度。")
        default: break
        }
        return notes
    }
}
