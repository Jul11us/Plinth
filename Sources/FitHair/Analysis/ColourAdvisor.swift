import CoreGraphics
import Foundation

/// What a photo says about colour: the undertone and depth of the skin, and how dark the hair is now.
/// Lighting shifts all of these, so everything built on them is worded as a suggestion.
struct ColourProfile: Equatable, Sendable, Codable {
    enum Undertone: String, Sendable, Codable { case warm, neutral, cool }
    enum Depth: String, Sendable, Codable { case light, medium, deep }

    /// Nil when the photo shows too little colour to judge (black-and-white, a plaster bust).
    var undertone: Undertone?
    var depth: Depth?
    /// Hair lightness on the 1 (black) to 10 (lightest blonde) scale colourists use; nil when no hair was found.
    var hairLevel: Int?
}

enum ColourAdvisor {
    // MARK: Reading the photo

    static func profile(photo: CGImage, face: FaceMeasurement) -> ColourProfile {
        let k = face.keyPoints
        let centre = CGPoint(x: (k.cheekLeft.x + k.cheekRight.x) / 2, y: (k.hairline.y + k.chin.y) / 2)
        let side = max(16, CGFloat(face.cheekWidth) * 2.6)
        let crop = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        guard let mask = HairSegmenter.segment(photo, crop: crop), let pixels = Thumbnail(photo, crop: crop) else {
            return ColourProfile()
        }
        var skin: [SIMD3<Float>] = [], hair: [SIMD3<Float>] = []
        for i in mask.labels.indices {
            if mask.labels[i] == HairSegmenter.Label.faceSkin.rawValue { skin.append(pixels.values[i]) }
            if mask.labels[i] == HairSegmenter.Label.hair.rawValue { hair.append(pixels.values[i]) }
        }
        var result = ColourProfile()
        if skin.count > 400 { (result.undertone, result.depth) = readSkin(skin) }
        if hair.count > 300 { result.hairLevel = level(forLuma: luma(median(hair))) }
        return result
    }

    /// Hue and lightness of the skin's middle tones in CIELAB. The hue bands are a rule of thumb
    /// placed around the 50–70° range skin normally falls in.
    static func readSkin(_ skin: [SIMD3<Float>]) -> (ColourProfile.Undertone?, ColourProfile.Depth?) {
        let middle = skin.sorted { luma($0) < luma($1) }
        let trimmed = Array(middle[(middle.count / 5)..<(middle.count * 4 / 5)])    // no shadows or shine
        let lab = toLab(median(trimmed))
        let chroma = hypot(lab.y, lab.z)
        guard chroma >= 8 else { return (nil, nil) }
        let hue = atan2(lab.z, lab.y) * 180 / .pi
        let undertone: ColourProfile.Undertone = hue >= 62 ? .warm : (hue <= 52 ? .cool : .neutral)
        let depth: ColourProfile.Depth = lab.x >= 70 ? .light : (lab.x >= 50 ? .medium : .deep)
        return (undertone, depth)
    }

    static func level(forLuma l: Float) -> Int { max(1, min(10, Int((1 + l * 16).rounded()))) }

    // MARK: Suggestions

    /// The three shades that sit best with this skin; empty when the skin couldn't be read.
    static func suggestions(for profile: ColourProfile?) -> [HairTryOn.Shade] {
        guard let undertone = profile?.undertone else { return [] }
        func score(_ s: HairTryOn.Shade) -> Int {
            var total = 0
            switch (s.warmth, undertone) {
            case (.neutral, _), (_, .neutral): total += 1
            case (.warm, .warm), (.cool, .cool): total += 2
            default: total -= 1
            }
            guard let level = s.level else { return total }
            switch profile?.depth {
            case .deep: total += level >= 8 ? -2 : (level <= 6 ? 1 : 0)
            case .light: total += level >= 5 ? 1 : 0
            default: break
            }
            return total
        }
        let wearable = HairTryOn.Shade.all.filter { $0.hex != nil && $0.family != .fashion }
        return Array(wearable.enumerated().sorted { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.prefix(3).map(\.element))
    }

    // MARK: Words for the colourist

    /// How much bleaching reaching a base level takes. Dye alone lifts about three levels.
    static func bleach(toBase base: Int, from current: Int) -> String {
        let lift = base - current
        if lift <= 0 { return "比现在深或差不多，不用漂" }
        if lift <= 3 { return "不用漂，直接染" }
        if lift <= 5 { return "要先漂 1 次" }
        if lift <= 7 { return "要先漂 1–2 次" }
        return "要先漂 2 次以上"
    }

    private static func hairWord(_ level: Int?) -> String {
        guard let level else { return "按深色头发估算" }
        return level <= 4 ? "现在是深色头发" : (level <= 7 ? "现在是棕色头发" : "现在是浅色头发")
    }

    /// e.g. "约 8 度，偏暖". Nil for keeping the natural colour.
    static func description(of shade: HairTryOn.Shade) -> String? {
        guard let level = shade.level else { return nil }
        return "约 \(level) 度，\(shade.warmth.label)"
    }

    /// e.g. "现在是深色头发，要先漂 1–2 次". Nil for keeping the natural colour.
    static func baseNote(for shade: HairTryOn.Shade, profile: ColourProfile?) -> String? {
        guard let base = shade.base else { return nil }
        let current = profile?.hairLevel
        return "\(hairWord(current))，\(bleach(toBase: base, from: current ?? 3))"
    }

    /// Extra rows for the barber card; none when the user keeps their own colour.
    static func cardRows(shade: HairTryOn.Shade, profile: ColourProfile?) -> [(String, String)] {
        guard let description = description(of: shade), let note = baseNote(for: shade, profile: profile) else { return [] }
        return [("发色", "\(shade.name)，\(description)"), ("打底", note + "。以理发师看发质为准")]
    }

    // MARK: Colour maths

    private static func median(_ v: [SIMD3<Float>]) -> SIMD3<Float> {
        let m = v.count / 2
        return SIMD3(v.map(\.x).sorted()[m], v.map(\.y).sorted()[m], v.map(\.z).sorted()[m])
    }

    private static func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

    /// sRGB (0…1) to CIELAB, D65. Returns (L*, a*, b*) as x, y, z.
    private static func toLab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = linear(c.x), g = linear(c.y), b = linear(c.z)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// The crop at the segmenter's resolution, so its labels line up pixel for pixel.
    private struct Thumbnail {
        var values: [SIMD3<Float>]

        init?(_ image: CGImage, crop: CGRect) {
            let n = HairSegmenter.side
            var bytes = [UInt8](repeating: 128, count: n * n * 4)
            let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
                guard let c = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return false }
                c.interpolationQuality = .high
                let s = CGFloat(n) / crop.width, h = CGFloat(image.height)
                c.draw(image, in: CGRect(x: -crop.minX * s, y: -(h - crop.maxY) * s, width: CGFloat(image.width) * s, height: h * s))
                return true
            }
            guard drawn else { return nil }
            values = (0..<(n * n)).map { SIMD3(Float(bytes[$0 * 4]), Float(bytes[$0 * 4 + 1]), Float(bytes[$0 * 4 + 2])) / 255 }
        }
    }
}
