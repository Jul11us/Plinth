import CoreGraphics
import Foundation

/// On-device hair preview: the carved hair of a plaster bust is lifted off, recoloured and laid on the
/// user's head, and the user's own hair is painted out where the new style doesn't cover it.
/// It is a sketch of the shape of a cut, not a photographic result.
enum HairTryOn {
    struct Output: @unchecked Sendable {
        let image: CGImage
        /// The user's photo framed the same way, for before / after.
        let original: CGImage
        /// Only with `forRepaint`: what a generative repaint of the hair needs besides `image`.
        var repaint: Repaint? = nil
    }

    /// Inputs for repainting the hair with an image model: `image` is the draft, `original` the photo, these say where.
    struct Repaint: @unchecked Sendable {
        /// White where the picture may be redrawn: the old hair that was painted out and the new hair, with a margin.
        /// Outside the photo, only where the new hair reaches.
        let mask: CGImage
        /// White where the new hair is.
        let hair: CGImage
        /// White on the skin the new hair meets: forehead, temples, in front of the ears. Redrawn together with the
        /// hair, so the hair gets a hairline and sideburns on this head instead of ending where the bust's did.
        let blend: CGImage
    }

    enum Failure: LocalizedError {
        case noBust, bustFace, segmenter, tooShort
        var errorDescription: String? {
            switch self {
            case .noBust: "这款发型还没有示意图。"
            case .bustFace: "这款发型的示意图对不上脸部位置。"
            case .segmenter: "头发识别模型没有加载成功。"
            case .tooShort: "这款还做不出试戴效果，可以先看发型示意图。"
            }
        }
    }

    /// A hair colour. `level` is the colourist's 1–10 depth; `base` is how light the hair has to be
    /// before the colour shows, which is what decides bleaching.
    struct Shade: Identifiable, Hashable, Sendable {
        enum Family: String, CaseIterable, Identifiable, Sendable {
            case natural = "自然", warm = "暖棕", cool = "冷棕灰", blonde = "金色", fashion = "时髦"
            var id: String { rawValue }
        }
        enum Warmth: Sendable {
            case warm, neutral, cool
            var label: String { self == .warm ? "偏暖" : (self == .cool ? "偏冷" : "中性") }
        }

        let id: String, name: String
        /// sRGB; nil keeps the colour found in the photo.
        let hex: UInt32?
        var family: Family = .natural
        var warmth: Warmth = .neutral
        var level: Int? = nil
        var base: Int? = nil

        static let auto = Shade(id: "auto", name: "原色", hex: nil)

        /// The colour in the words an image model knows; nil keeps the colour found in the photo.
        var promptName: String? {
            ["black": "black", "brown": "dark brown", "blueblack": "blue black", "blacktea": "brownish black",
             "mocha": "dark mocha brown", "redtea": "dark mahogany red brown", "chestnut": "chestnut brown",
             "caramel": "caramel brown", "honey": "honey brown", "milktea": "light beige brown",
             "coolbrown": "cool ash brown", "cooltea": "cool mushroom brown", "mattegreen": "muted olive ash green", "ash": "ash grey blonde", "smoke": "smoke grey",
             "blonde": "light golden blonde", "platinum": "platinum blonde", "blue": "dusty blue",
             "pinkbrown": "dusty rose pink brown", "plum": "blackish dark plum", "wine": "dark burgundy wine red",
             "orange": "muted copper orange brown", "taro": "pale dusty lavender"][id]
        }
        static let all: [Shade] = [
            auto,
            Shade(id: "black", name: "黑", hex: 0x17140F, family: .natural, warmth: .neutral, level: 2, base: 2),
            Shade(id: "brown", name: "深棕", hex: 0x3A271A, family: .natural, warmth: .neutral, level: 4, base: 4),
            Shade(id: "blueblack", name: "蓝黑", hex: 0x10151F, family: .natural, warmth: .cool, level: 2, base: 2),
            Shade(id: "blacktea", name: "黑茶", hex: 0x2A211C, family: .natural, warmth: .neutral, level: 3, base: 3),
            Shade(id: "mocha", name: "摩卡棕", hex: 0x4E3A2F, family: .warm, warmth: .neutral, level: 5, base: 5),
            Shade(id: "redtea", name: "红茶棕", hex: 0x5C3226, family: .warm, warmth: .warm, level: 5, base: 5),
            Shade(id: "chestnut", name: "栗棕", hex: 0x6A4227, family: .warm, warmth: .warm, level: 6, base: 6),
            Shade(id: "caramel", name: "焦糖", hex: 0x8A5A32, family: .warm, warmth: .warm, level: 7, base: 7),
            Shade(id: "honey", name: "蜜茶棕", hex: 0x9C7040, family: .warm, warmth: .warm, level: 7, base: 8),
            Shade(id: "milktea", name: "奶茶", hex: 0xA58662, family: .warm, warmth: .warm, level: 8, base: 8),
            Shade(id: "coolbrown", name: "冷棕", hex: 0x4A3F3A, family: .cool, warmth: .cool, level: 5, base: 5),
            Shade(id: "cooltea", name: "冷茶棕", hex: 0x6E5E52, family: .cool, warmth: .cool, level: 6, base: 6),
            Shade(id: "mattegreen", name: "闷青", hex: 0x5E6453, family: .cool, warmth: .cool, level: 6, base: 8),
            Shade(id: "ash", name: "亚麻灰", hex: 0x8E8578, family: .cool, warmth: .cool, level: 8, base: 8),
            Shade(id: "smoke", name: "烟灰", hex: 0x9A9A98, family: .cool, warmth: .cool, level: 9, base: 9),
            Shade(id: "blonde", name: "浅金", hex: 0xC9AC78, family: .blonde, warmth: .warm, level: 9, base: 9),
            Shade(id: "platinum", name: "白金", hex: 0xDCCFB4, family: .blonde, warmth: .cool, level: 10, base: 10),
            Shade(id: "blue", name: "雾霾蓝", hex: 0x4F6272, family: .fashion, warmth: .cool, level: 6, base: 9),
            Shade(id: "pinkbrown", name: "粉棕", hex: 0x9A6B62, family: .fashion, warmth: .warm, level: 7, base: 8),
            Shade(id: "plum", name: "葡萄紫", hex: 0x4B3449, family: .fashion, warmth: .cool, level: 5, base: 7),
            Shade(id: "wine", name: "酒红", hex: 0x5C1F2A, family: .fashion, warmth: .neutral, level: 4, base: 6),
            Shade(id: "orange", name: "脏橘", hex: 0xB0622F, family: .fashion, warmth: .warm, level: 7, base: 8),
            Shade(id: "taro", name: "芋泥紫", hex: 0x9E8AA8, family: .fashion, warmth: .cool, level: 8, base: 10),
        ]
    }

    static let width = 960, height = 1200
    /// Mirroring swaps the side of a parting, so it waits until the two heads face this far apart (in `turn`).
    static let mirrorBeyond = 0.15
    /// A head that turns carries its hair across its face: about this many eye-distances per unit of `turn`,
    /// measured on the busts.
    static let slidePerTurn: CGFloat = 1.4
    /// How far from the new hair the skin is handed to the repaint with it: enough for a hairline and sideburns.
    static let blendReach = 28
    /// How strongly the light and shade of the carving are put into a draft that will be repainted. The repaint
    /// keeps of the draft what survives the noise it starts from. At the 1.5 that looks right to the eye, dark hair
    /// is nearly flat, and the locks are redrawn the model's way: a spiky quiff comes out slicked back. Overdrawn
    /// like this, where the locks lie and which way they point comes through.
    private static let reliefForRepaint: Float = 4
    /// How far below a fringe the forehead is redrawn with it.
    private static let fringeReach = 36
    /// In the canvas the pupils sit this far apart, at this height: the framing of the busts themselves.
    private static let pupilGap: CGFloat = 158, pupilY: CGFloat = 470

    static func render(photo: CGImage, face: FaceMeasurement, bust: CGImage, bustFace: FaceMeasurement, shade: Shade,
                       forRepaint: Bool = false, matchTurn: Bool = true, fadeHeight: Double? = nil) throws -> Output {
        guard HairSegmenter.isAvailable else { throw Failure.segmenter }

        // The busts look to one side, some left, some right, by different amounts, and their hair is carved as seen
        // from there. When the user looks well the other way, start from the bust's mirror image.
        var bust = bust, bustFace = bustFace
        if matchTurn, face.turn * bustFace.turn < 0, abs(face.turn - bustFace.turn) > Self.mirrorBeyond,
           let flipped = mirrored(bust), let flippedFace = try? FaceAnalyzer.analyze(flipped) {
            bust = flipped
            bustFace = flippedFace
        }
        // What difference is left is taken out below by sliding the hair across the face.
        let turned = matchTurn ? bustFace.turn - face.turn : 0

        // 1. Both pictures on one canvas: the user's by their pupils, the bust so its face is the user's width.
        let toCanvas = framing(face)
        let userScale = hypot(toCanvas.a, toCanvas.b)
        let userCheeks = CGFloat(face.cheekWidth) * userScale
        let bustToCanvas = aligned(bustFace, faceWidth: userCheeks)

        guard let user = Raster(photo, transform: toCanvas, width: width, height: height),
              let placed = Raster(bust, transform: bustToCanvas, width: width, height: height) else { throw Failure.segmenter }

        // 2. Bend the bust so its face outline lands on the user's. This is what makes the hair sit against
        // this particular head, and it also straightens the busts, which are turned about 10°.
        // Around the skull the hair also slides sideways to where it would be on a head turned like the user's:
        // towards the side the bust faces, since a turned head shows its hair on the other side of its face.
        let slide = max(-0.5, min(0.5, slidePerTurn * CGFloat(turned))) * pupilGap
        let skull = (0...8).map { k -> CGPoint in
            let angle = CGFloat.pi * CGFloat(k) / 8
            return CGPoint(x: CGFloat(width) / 2 + pupilGap * 1.75 * cos(angle), y: pupilY - pupilGap * (0.2 + 2 * sin(angle)))
        }
        // The busts have low, heavy brows. A fringe is read against the brows, so theirs go onto the sitter's:
        // without that a fringe carved to end mid-forehead comes down over a real person's eyebrows.
        var from = anchors(bustFace, bustToCanvas) + skull
        var to = anchors(face, toCanvas) + skull.map { CGPoint(x: $0.x + slide, y: $0.y) }
        if let theirs = bustFace.brows, let own = face.brows, theirs.count == own.count {
            from += theirs.map { $0.applying(bustToCanvas) }
            to += own.map { $0.applying(toCanvas) }
        }
        let plaster = placed.warped(field: fitField(from: from, to: to))

        // 3. Where the hair is, in each.
        guard let userLabels = segment(user), let bustLabels = segment(plaster) else { throw Failure.segmenter }
        let oldHair = soft(userLabels, .hair)
        let lum = plaster.luminance
        // Feather the 256-px mask along the carved edges of the bust at full resolution.
        var newHair = guidedFilter(guide: lum, input: soft(bustLabels, .hair), width: width, height: height, radius: 14, eps: 0.0008)
        for i in newHair.indices { newHair[i] = smoothstep(0.32, 0.72, newHair[i]) * plaster.coverage[i] }
        cleanUp(&newHair)
        guard coversCrown(newHair) else { throw Failure.tooShort }

        // 4. Never put hair over the eyes, nose or mouth, whatever the style's fringe does.
        let eyeMid = CGPoint(x: CGFloat(width) / 2, y: pupilY)
        for y in 0..<height {
            for x in 0..<width {
                let dx = (CGFloat(x) - eyeMid.x) / (pupilGap * 0.95)
                let dy = (CGFloat(y) - (eyeMid.y + pupilGap * 0.75)) / (pupilGap * 1.04)
                newHair[y * width + x] *= smoothstep(0.75, 1.05, Float(hypot(dx, dy)))
            }
        }

        // 5. Paint out the old hair, and anything outside the photo.
        var gone = oldHair.map { $0 > 0.35 ? Float(1) : 0 }
        if forRepaint {
            // A repaint can rebuild what is under a hat or a headphone band, so those go too: anything worn on
            // the skull above the brows. Glasses and earrings are below the line and stay.
            let worn = zip(soft(userLabels, .clothes), soft(userLabels, .other)).map { max($0, $1) }
            let top = Int(pupilY - pupilGap * 0.5)
            for y in 0..<max(0, top) {
                let dy = (CGFloat(y) - (pupilY - pupilGap * 0.6)) / (pupilGap * 1.9)
                for x in 0..<width {
                    let dx = (CGFloat(x) - CGFloat(width) / 2) / (pupilGap * 1.7)
                    if dx * dx + dy * dy < 1, worn[y * width + x] > 0.5 { gone[y * width + x] = 1 }
                }
            }
        }
        if forRepaint {
            gone = withLooseStrands(gone, photo: user.pixels, labels: userLabels)
            gone = withFringe(gone, photo: user.pixels, labels: userLabels)
        }
        var erase = box(gone, width: width, height: height, radius: forRepaint ? 14 : 9)
        for i in erase.indices { erase[i] = erase[i] > 0.02 ? 1 : 0 }
        if forRepaint {
            // Under a fringe the forehead keeps thin strands and slivers of skin between them, which survive as
            // streaks. The forehead near the old hair goes as a whole; the repaint draws it again.
            let wide = box(gone, width: width, height: height, radius: fringeReach)
            let face = soft(userLabels, .faceSkin)
            for y in max(0, Int(pupilY - pupilGap * 2.2))..<Int(pupilY - pupilGap * 0.5) {
                for x in max(0, width / 2 - Int(pupilGap * 1.2))..<min(width, width / 2 + Int(pupilGap * 1.2))
                where wide[y * width + x] > 0.02 && face[y * width + x] > 0.5 { erase[y * width + x] = 1 }
            }
        }
        let keep: [Float] = zip(erase, user.coverage).map { (1 - $0) * ($1 > 0.99 ? 1 : 0) }
        let base = pullPush(user.pixels, weights: keep, width: width, height: height)

        // 6. Recolour the plaster: its light and shade become the strands of the new hair.
        let colour = shade.hex.map(simd) ?? foundColour(user.pixels, mask: oldHair) ?? simd(0x2B2320)
        // Measured against the median, so a typical strand comes out the colour of the swatch.
        let hairTones = newHair.indices.filter { newHair[$0] > 0.5 }.map { lum[$0] }.sorted()
        let typical = hairTones.isEmpty ? 0.7 : hairTones[hairTones.count / 2]
        let crown = (newHair.firstIndex { $0 > 0.5 } ?? 0) / width
        let ramp = HairRamp(colour)

        // Real hair is thousands of slightly different strands in clumps, so grow both kinds of variation
        // along the direction the carved hair runs.
        let flow = strandFlow(lum)
        let fine = strandNoise(flow: flow, mask: newHair, reach: 14, cell: 1, seed: 11)
        let clumps = strandNoise(flow: flow, mask: newHair, reach: 26, cell: 5, seed: 23)
        let softened = box(lum, width: width, height: height, radius: 2)
        // How bright the carving is around each point, over the hair only: the bust is lit from one side, and this
        // is what tells that from the rise and fall of the locks.
        let inHair = newHair.map { $0 > 0.5 ? Float(1) : 0 }
        let hairWeight = box(inHair, width: width, height: height, radius: 20)
        let hairLight = box(zip(lum, inHair).map { $0 * $1 }, width: width, height: height, radius: 20)

        // Hair close to the skin sits in shadow; at the outer edge it thins out instead of ending in a cut line.
        let body = box(newHair, width: width, height: height, radius: 6)
        let skin = zip(soft(userLabels, .faceSkin), soft(userLabels, .bodySkin)).map { min(1, $0 + $1) }
        let nearSkin = box(skin, width: width, height: height, radius: 18)
        let shadow = box(newHair, width: width, height: height, radius: 16)
        let light = photoLight(user.pixels, skin: skin)

        // Sides clipped short are carved on the bust as a smooth surface, and painted as hair they come out as a
        // solid block of the hair colour. There the scalp shows through, more of it the nearer the ear.
        let clipped = fadeHeight.map { clippedSides(lum, hair: newHair, top: CGFloat($0), middle: CGFloat(width) / 2 + slide) }
        let scalp = (skinColour(user.pixels, skin: skin) ?? SIMD3(0.8, 0.62, 0.52)) * 0.9

        // 7. Composite.
        var result = [SIMD3<Float>](repeating: .zero, count: base.count)
        for i in result.indices {
            var a0 = newHair[i]
            var shaded = base[i] * (1 - 0.3 * shadow[i] * (1 - a0) * skin[i])
            if let clipped, clipped.amount[i] > 0, a0 > 0 {
                shaded += (scalp - shaded) * clipped.amount[i] * a0
                a0 *= 1 - clipped.amount[i] * (1 - clipped.density[i])
            }
            guard a0 > 0 else { result[i] = shaded; continue }
            let y = i / width, x = i % width
            let carved = lum[i] * 0.55 + softened[i] * 0.45
            var v: Float
            if forRepaint {
                // Only the locks are overdrawn. Overdrawing the side of the bust that is in shade as well turns
                // half the head into a flat black patch, and the repaint draws that half without any locks.
                let around = hairWeight[i] > 0.05 ? hairLight[i] / hairWeight[i] : typical
                let lock = carved / max(0.05, around) - 1
                // Overdrawn highlights turn into white streaks in the repaint, so only the shade gets all of it.
                v = 0.5 + (around / max(0.05, typical) - 1) * 1.5 + lock * (lock > 0 ? reliefForRepaint * 0.6 : reliefForRepaint)
            } else {
                v = 0.5 + (carved / max(0.05, typical) - 1) * 1.5
            }
            v += fine[i] * 0.13 + clumps[i] * 0.13
            // Deeper at the root, deeper where it lies against the skin.
            let along = min(1, Float(y - crown) / Float(pupilGap * 1.5))
            v -= (1 - along) * 0.12 + nearSkin[i] * 0.1
            // The band of shine that runs around the head, broken up by the strands.
            let wave = 22 * sin(Float(x) / 90) + 40 * clumps[i]
            let band = (Float(y) - Float(pupilY - pupilGap * 0.75) + wave) / 62
            v += exp(-band * band) * (0.16 + 0.12 * max(0, fine[i]))
            // Clipped hair is closer to an even stubble: carved strands at half strength over the scalp read as grey
            // spikes. Only half-way there, though: a perfectly even patch gets a bright line drawn along its edge.
            if let clipped { v += (0.4 - v) * clipped.amount[i] * 0.5 }
            var strands = ramp.colour(at: v)
            strands *= 1 + SIMD3<Float>(fine[i] * 0.05, 0, -fine[i] * 0.05)     // a little warm and cool between strands
            strands *= light
            let edge = 1 - smoothstep(0.62, 0.98, body[i])
            let a = a0 * (1 - edge * 0.65 * (0.5 - 0.5 * fine[i]))
            result[i] = shaded * (1 - a) + strands * a
        }

        guard let image = makeImage(result, width: width, height: height),
              let original = makeImage(base.indices.map { user.coverage[$0] > 0.99 ? user.pixels[$0] : base[$0] }, width: width, height: height)
        else { throw Failure.segmenter }
        guard forRepaint else { return Output(image: image, original: original) }

        // Everything that changed, grown a little so a repaint has room for loose strands and a soft hairline.
        let changed = zip(erase, newHair).map { max($0, $1 > 0.05 ? Float(1) : 0) }
        var redraw = box(changed, width: width, height: height, radius: 10)
        // Outside the photo there is only the smoothed-over continuation of its edge. Nothing is cleared out there,
        // but the new hair may reach into it: hair cut off flat at the edge of the photo looks worse.
        let reaches = box(newHair.map { $0 > 0.05 ? Float(1) : 0 }, width: width, height: height, radius: 10)
        for i in redraw.indices { redraw[i] = redraw[i] > 0.02 && (user.coverage[i] > 0.99 || reaches[i] > 0.02) ? 1 : 0 }
        // The skin right next to the new hair, never the eyes, brows, nose or mouth.
        let nearHair = box(newHair.map { $0 > 0.05 ? Float(1) : 0 }, width: width, height: height, radius: blendReach)
        var blend = [Float](repeating: 0, count: newHair.count)
        for y in 0..<height {
            let dy = (CGFloat(y) - (pupilY + pupilGap * 0.75)) / (pupilGap * 1.25)
            for x in 0..<width {
                let i = y * width + x
                let dx = (CGFloat(x) - CGFloat(width) / 2) / (pupilGap * 1.1)
                // The features are a rounded box from above the brows to below the mouth.
                guard nearHair[i] > 0.02, skin[i] > 0.5 || erase[i] > 0, user.coverage[i] > 0.99, pow(dx, 4) + pow(dy, 4) > 1 else { continue }
                blend[i] = 1
            }
        }
        guard let mask = makeImage(redraw.map { SIMD3(repeating: $0) }, width: width, height: height),
              let hair = makeImage(newHair.map { SIMD3(repeating: $0) }, width: width, height: height),
              let band = makeImage(blend.map { SIMD3(repeating: $0) }, width: width, height: height)
        else { throw Failure.segmenter }
        return Output(image: image, original: original, repaint: Repaint(mask: mask, hair: hair, blend: band))
    }

    // MARK: Geometry

    /// Photo pixels → canvas: pupils level, the standard distance apart, centred.
    private static func framing(_ m: FaceMeasurement) -> CGAffineTransform {
        let l = m.keyPoints.pupilLeft, r = m.keyPoints.pupilRight
        let scale = pupilGap / max(1, hypot(r.x - l.x, r.y - l.y))
        return transform(l, r, scale: scale)
    }

    /// Bust pixels → canvas: same pupil position, scaled so the cheekbones match the user's.
    private static func aligned(_ m: FaceMeasurement, faceWidth: CGFloat) -> CGAffineTransform {
        transform(m.keyPoints.pupilLeft, m.keyPoints.pupilRight, scale: faceWidth / max(1, CGFloat(m.cheekWidth)))
    }

    private static func transform(_ l: CGPoint, _ r: CGPoint, scale: CGFloat) -> CGAffineTransform {
        let angle = atan2(r.y - l.y, r.x - l.x)
        let mid = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
        return CGAffineTransform(translationX: CGFloat(width) / 2, y: pupilY)
            .rotated(by: -angle).scaledBy(x: scale, y: scale).translatedBy(x: -mid.x, y: -mid.y)
    }

    private static func mirrored(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.translateBy(x: CGFloat(image.width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    // MARK: Segmentation

    private static func segment(_ r: Raster) -> HairSegmenter.Mask? {
        guard let image = makeImage(r.pixels, width: width, height: height) else { return nil }
        let side = CGFloat(max(width, height))
        return HairSegmenter.segment(image, crop: CGRect(x: (CGFloat(width) - side) / 2, y: (CGFloat(height) - side) / 2, width: side, height: side))
    }

    /// Where a face's outline and upper edge are on the canvas: the same 23 places on any face.
    private static func anchors(_ m: FaceMeasurement, _ t: CGAffineTransform) -> [CGPoint] {
        let k = m.keyPoints
        return (resample(m.contour, count: 17) + [k.hairline, k.foreheadLeft, k.foreheadRight, k.pupilLeft, k.pupilRight, k.chin])
            .map { $0.applying(t) }
    }

    private static func resample(_ line: [CGPoint], count: Int) -> [CGPoint] {
        guard line.count > 1 else { return Array(repeating: line.first ?? .zero, count: count) }
        var lengths: [CGFloat] = [0]
        for i in 1..<line.count { lengths.append(lengths[i - 1] + hypot(line[i].x - line[i - 1].x, line[i].y - line[i - 1].y)) }
        let total = max(1, lengths[lengths.count - 1])
        var j = 0
        return (0..<count).map { n in
            let target = total * CGFloat(n) / CGFloat(count - 1)
            while j < line.count - 2 && lengths[j + 1] < target { j += 1 }
            let t = (target - lengths[j]) / max(0.001, lengths[j + 1] - lengths[j])
            return CGPoint(x: line[j].x + (line[j + 1].x - line[j].x) * t, y: line[j].y + (line[j + 1].y - line[j].y) * t)
        }
    }

    /// For each canvas point, how far back to look in the bust: a smooth blend of how far each anchor has to
    /// move, worked out on a coarse grid. Hair far from the face simply travels with its nearest part of the face.
    private static func fitField(from source: [CGPoint], to target: [CGPoint]) -> WarpField {
        let step = 8, gw = width / step + 2, gh = height / step + 2
        var dx = [Float](repeating: 0, count: gw * gh), dy = dx
        for y in 0..<gh {
            for x in 0..<gw {
                let q = CGPoint(x: x * step, y: y * step)
                var sumX: CGFloat = 0, sumY: CGFloat = 0, sumW: CGFloat = 0
                for i in target.indices {
                    let d2 = pow(q.x - target[i].x, 2) + pow(q.y - target[i].y, 2)
                    let w = 1 / pow(d2 + 900, 1.5)
                    sumX += w * (target[i].x - source[i].x); sumY += w * (target[i].y - source[i].y); sumW += w
                }
                let mx = sumX / sumW, my = sumY / sumW
                let limit = min(1, 110 / max(0.001, hypot(mx, my)))
                dx[y * gw + x] = Float(mx * limit); dy[y * gw + x] = Float(my * limit)
            }
        }
        return WarpField(dx: dx, dy: dy, width: gw, height: gh, step: step)
    }

    /// Very short or very smooth carved hair can defeat the segmenter and leave a patchy cap; better no preview than that.
    private static func coversCrown(_ hair: [Float]) -> Bool {
        let y = Int(pupilY - pupilGap * 1.15), x0 = width / 2 - Int(pupilGap * 0.8), x1 = width / 2 + Int(pupilGap * 0.8)
        let columns = (x0..<x1).filter { x in (max(0, y - 60)..<y).contains { hair[$0 * width + x] > 0.5 } }
        guard columns.count * 10 >= (x1 - x0) * 8 else { return false }
        // Both sides of the crown have to be there; a mask with one side missing looks broken on a head.
        let lowestTop = Int(pupilY - pupilGap)
        return [x0, x1 - 1].allSatisfy { x in (0..<lowestTop).contains { hair[$0 * width + x] > 0.5 } }
    }

    /// Removes specks the segmenter left beside the hair and fills small holes inside it.
    private static func cleanUp(_ matte: inout [Float]) {
        let parts = regions(matte.map { $0 > 0.5 })
        guard let largest = parts.map(\.count).max() else { return }
        for part in parts where part.count < largest / 12 { for i in part { matte[i] = 0 } }
        for hole in regions(matte.map { $0 <= 0.5 })
        where hole.count < width * height / 60 && !hole.contains(where: { $0 < width || $0 >= width * (height - 1) || $0 % width == 0 || $0 % width == width - 1 }) {
            for i in hole { matte[i] = 1 }
        }
    }

    private static func regions(_ on: [Bool]) -> [[Int]] {
        var seen = [Bool](repeating: false, count: on.count), result: [[Int]] = []
        for start in on.indices where on[start] && !seen[start] {
            var stack = [start], region: [Int] = []
            seen[start] = true
            while let i = stack.popLast() {
                region.append(i)
                let x = i % width
                for n in [x > 0 ? i - 1 : -1, x < width - 1 ? i + 1 : -1, i - width, i + width]
                where n >= 0 && n < on.count && on[n] && !seen[n] {
                    seen[n] = true; stack.append(n)
                }
            }
            result.append(region)
        }
        return result
    }

    /// Where a picture on the canvas has hair, 0…1; nil when the model is missing.
    static func hairMap(of pixels: [SIMD3<Float>]) -> [Float]? {
        guard let image = makeImage(pixels, width: width, height: height) else { return nil }
        let side = CGFloat(max(width, height))
        return HairSegmenter.segment(image, crop: CGRect(x: (CGFloat(width) - side) / 2, y: (CGFloat(height) - side) / 2, width: side, height: side))
            .map { soft($0, .hair) }
    }

    /// The hair map is 256 pixels across and misses what is thin: flyaways, spikes, the frayed edge of the hair.
    /// Left in the photo, they show through beside the new hair. They are found by colour: within reach of the hair,
    /// whatever is neither skin nor clothes and has moved from the background around it towards the hair's colour.
    /// Only what touches the hair counts, so something dark behind the head stays where it is.
    private static func withLooseStrands(_ hair: [Float], photo: [SIMD3<Float>], labels: HairSegmenter.Mask) -> [Float] {
        guard let colour = foundColour(photo, mask: hair) else { return hair }
        let w = width, h = height
        let body = zip(zip(soft(labels, .faceSkin), soft(labels, .bodySkin)), soft(labels, .clothes)).map { $0.0 + $0.1 + $1 > 0.5 }
        let within = box(hair, width: w, height: h, radius: 60)
        // The background around each point: an average that leaves out the hair, a margin around it, and the body.
        let margin = box(hair, width: w, height: h, radius: 8)
        let counted = hair.indices.map { margin[$0] < 0.001 && !body[$0] ? Float(1) : 0 }
        let weight = box(counted, width: w, height: h, radius: 24)
        let around = (0..<3).map { c in box(hair.indices.map { photo[$0][c] * counted[$0] }, width: w, height: h, radius: 24) }

        var strand = [Bool](repeating: false, count: hair.count)
        for i in hair.indices where within[i] > 0.001 && hair[i] < 0.5 && !body[i] && weight[i] > 0.05 {
            let back = SIMD3(around[0][i], around[1][i], around[2][i]) / weight[i]
            let toHair = colour - back
            let contrast = (toHair * toHair).sum()
            // Hair against a background of its own colour can't be told apart this way.
            guard contrast > 0.03 else { continue }
            strand[i] = ((photo[i] - back) * toHair).sum() / contrast > 0.3
        }
        // Spread from the hair through whatever was marked.
        var out = hair
        var edge = hair.indices.filter { hair[$0] >= 0.5 }
        while let i = edge.popLast() {
            let x = i % w
            for n in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, i - w, i + w] where n >= 0 && n < out.count && strand[n] && out[n] < 0.5 {
                out[n] = 1
                edge.append(n)
            }
        }
        return out
    }

    /// The tips of a fringe and the shade under it are read as skin by the hair map, and stay on the forehead as a
    /// dark smudge once the fringe is gone. On the forehead, skin that has moved from the colour of the cheeks
    /// towards the hair's, and touches the hair, goes with the hair.
    private static func withFringe(_ hair: [Float], photo: [SIMD3<Float>], labels: HairSegmenter.Mask) -> [Float] {
        guard let colour = foundColour(photo, mask: hair) else { return hair }
        let w = width, h = height
        let face = soft(labels, .faceSkin)
        func rows(_ from: CGFloat, _ to: CGFloat) -> Range<Int> { max(0, Int(pupilY + pupilGap * from))..<min(h, Int(pupilY + pupilGap * to)) }
        func columns(_ reach: CGFloat) -> Range<Int> { max(0, w / 2 - Int(pupilGap * reach))..<min(w, w / 2 + Int(pupilGap * reach)) }
        // The cheeks and nose: skin that no fringe reaches.
        var cheeks: [SIMD3<Float>] = []
        for y in rows(0.25, 1) where y % 3 == 0 {
            for x in columns(0.85) where x % 3 == 0 && face[y * w + x] > 0.9 && hair[y * w + x] < 0.5 { cheeks.append(photo[y * w + x]) }
        }
        guard cheeks.count > 200 else { return hair }
        let middle = cheeks.count / 2
        let skin = SIMD3(cheeks.map(\.x).sorted()[middle], cheeks.map(\.y).sorted()[middle], cheeks.map(\.z).sorted()[middle])
        let toHair = colour - skin
        let contrast = (toHair * toHair).sum()
        guard contrast > 0.03 else { return hair }

        var out = hair
        // Above the brows only: down here a dark patch may be an eyebrow or the rim of a pair of glasses.
        let forehead = rows(-2.2, -0.45), across = columns(1.2)
        var edge = forehead.flatMap { y in across.map { y * w + $0 } }.filter { hair[$0] >= 0.5 }
        while let i = edge.popLast() {
            let x = i % w
            for n in [i - 1, i + 1, i - w, i + w] where forehead.contains(n / w) && across.contains(n % w) && abs(n % w - x) <= 1 && out[n] < 0.5 {
                guard face[n] > 0.5, ((photo[n] - skin) * toHair).sum() / contrast > 0.35 else { continue }
                out[n] = 1
                edge.append(n)
            }
        }
        return out
    }

    /// Where a fade leaves the hair too short to cover the scalp: on the sides of the head, below `top`
    /// (eye-distances above the pupils), where the bust is carved smooth rather than in strands.
    /// `density` is how much hair is left there: little at the ear, all of it at `top`.
    /// `middle` is where the middle of the hair is across the canvas, which is not the middle of the face when the
    /// hair has been slid to follow a turned head.
    private static func clippedSides(_ lum: [Float], hair: [Float], top: CGFloat, middle centre: CGFloat) -> (amount: [Float], density: [Float]) {
        let w = width, h = height
        // How much the carving rises and falls around each point, against its own brightness.
        let inside = hair.map { $0 > 0.5 ? Float(1) : 0 }
        let smooth = box(lum, width: w, height: h, radius: 3)
        let weight = box(inside, width: w, height: h, radius: 14)
        let mean = box(zip(smooth, inside).map { $0 * $1 }, width: w, height: h, radius: 14)
        let square = box(zip(smooth, inside).map { $0 * $0 * $1 }, width: w, height: h, radius: 14)

        var amount = [Float](repeating: 0, count: hair.count), density = [Float](repeating: 1, count: hair.count)
        let full = pupilY - pupilGap * top, ear = pupilY
        for y in max(0, Int(full - pupilGap * 0.2))..<h {
            let below = smoothstep(Float(full - pupilGap * 0.15), Float(full + pupilGap * 0.1), Float(y))
            let left = max(0, min(1, Float((ear - CGFloat(y)) / (ear - full))))
            for x in 0..<w {
                let i = y * w + x
                guard hair[i] > 0, weight[i] > 0.05 else { continue }
                let side = smoothstep(0.7, 0.95, Float(abs(CGFloat(x) - centre) / pupilGap))
                let middle = mean[i] / weight[i]
                let relief = (max(0, square[i] / weight[i] - middle * middle)).squareRoot() / max(0.05, middle)
                amount[i] = below * side * (1 - smoothstep(0.04, 0.09, relief))
                density[i] = 0.3 + 0.7 * left
            }
        }
        return (box(amount, width: w, height: h, radius: 4), density)
    }

    /// The median colour of the sitter's skin; nil when too little of it shows.
    private static func skinColour(_ pixels: [SIMD3<Float>], skin: [Float]) -> SIMD3<Float>? {
        let found = stride(from: 0, to: pixels.count, by: 7).filter { skin[$0] > 0.8 }.map { pixels[$0] }
        guard found.count > 200 else { return nil }
        let middle = found.count / 2
        return SIMD3(found.map(\.x).sorted()[middle], found.map(\.y).sorted()[middle], found.map(\.z).sorted()[middle])
    }

    /// One label of the 256×256 map, bilinearly enlarged to the canvas.
    private static func soft(_ m: HairSegmenter.Mask, _ label: HairSegmenter.Label) -> [Float] {
        let n = HairSegmenter.side
        let map = m.labels.map { $0 == label.rawValue ? Float(1) : 0 }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let v = (CGFloat(y) + 0.5 - m.crop.minY) / m.crop.height * CGFloat(n) - 0.5
            for x in 0..<width {
                let u = (CGFloat(x) + 0.5 - m.crop.minX) / m.crop.width * CGFloat(n) - 0.5
                let x0 = max(0, min(n - 2, Int(u))), y0 = max(0, min(n - 2, Int(v)))
                let fx = Float(max(0, min(1, u - CGFloat(x0)))), fy = Float(max(0, min(1, v - CGFloat(y0))))
                let top = map[y0 * n + x0] * (1 - fx) + map[y0 * n + x0 + 1] * fx
                let bottom = map[(y0 + 1) * n + x0] * (1 - fx) + map[(y0 + 1) * n + x0 + 1] * fx
                out[y * width + x] = top * (1 - fy) + bottom * fy
            }
        }
        return out
    }

    // MARK: Colour

    /// The median colour of the photo's hair; nil when there is too little to judge (short hair, a hat).
    private static func foundColour(_ pixels: [SIMD3<Float>], mask: [Float]) -> SIMD3<Float>? {
        let hair = pixels.indices.filter { mask[$0] > 0.85 }
        guard hair.count > pixels.count / 200 else { return nil }
        let step = max(1, hair.count / 4000)
        let sample = stride(from: 0, to: hair.count, by: step).map { pixels[hair[$0]] }
        let middle = sample.count / 2
        return SIMD3(sample.map(\.x).sorted()[middle], sample.map(\.y).sorted()[middle], sample.map(\.z).sorted()[middle])
    }

    /// Maps light and shade onto a hair colour, the way a colourist's gradient map does: shadows deeper and
    /// richer than the colour, highlights paler and slightly warm. Plain multiplying looks like paint.
    private struct HairRamp {
        let shadow: SIMD3<Float>, mid: SIMD3<Float>, high: SIMD3<Float>

        init(_ c: SIMD3<Float>) {
            mid = c
            let richer = SIMD3(pow(c.x, 1.45), pow(c.y, 1.45), pow(c.z, 1.45))
            shadow = richer * 0.5
            let lift = 0.14 + 0.3 * (0.299 * c.x + 0.587 * c.y + 0.114 * c.z)
            high = c + (SIMD3<Float>(1, 0.95, 0.88) - c) * lift
        }

        func colour(at v: Float) -> SIMD3<Float> {
            let t = max(0, min(1, v))
            return t < 0.5 ? shadow + (mid - shadow) * (t * 2) : mid + (high - mid) * ((t - 0.5) * 2)
        }
    }

    /// Dims or tints the hair to suit the photo, judged from the skin. Limited: skin itself varies.
    private static func photoLight(_ pixels: [SIMD3<Float>], skin: [Float]) -> SIMD3<Float> {
        var sum = SIMD3<Float>.zero, n: Float = 0
        for i in stride(from: 0, to: pixels.count, by: 7) where skin[i] > 0.8 { sum += pixels[i]; n += 1 }
        guard n > 200 else { return SIMD3(repeating: 1) }
        let mean = sum / n, level = luma(mean)
        let exposure = max(0.7, min(1.08, level / 0.6))
        let cast = mean / max(0.05, level)
        return (SIMD3(repeating: 1) + (cast - SIMD3(repeating: 1)) * 0.12) * exposure
    }

    private static func simd(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 255) / 255, Float((hex >> 8) & 255) / 255, Float(hex & 255) / 255)
    }

    private static func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

    // MARK: Strands

    /// The direction the carved strands run at each pixel, from the smoothed structure tensor of the bust.
    private static func strandFlow(_ lum: [Float]) -> [SIMD2<Float>] {
        var jxx = [Float](repeating: 0, count: lum.count), jxy = jxx, jyy = jxx
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let gx = lum[i + 1] - lum[i - 1], gy = lum[i + width] - lum[i - width]
                jxx[i] = gx * gx; jxy[i] = gx * gy; jyy[i] = gy * gy
            }
        }
        let a = box(jxx, width: width, height: height, radius: 6)
        let b = box(jxy, width: width, height: height, radius: 6)
        let c = box(jyy, width: width, height: height, radius: 6)
        return lum.indices.map { i in
            let angle = 0.5 * atan2(2 * b[i], a[i] - c[i]) + .pi / 2
            return SIMD2(cos(angle), sin(angle))
        }
    }

    /// Noise smeared along the strands, about −1…1. `cell` sets how wide a strand or clump is.
    private static func strandNoise(flow: [SIMD2<Float>], mask: [Float], reach: Int, cell: Int, seed: UInt64) -> [Float] {
        var rng = SplitMix(state: seed)
        let columns = width / cell + 1, rows = height / cell + 1
        let grain = (0..<(columns * rows)).map { _ in Float(rng.unit()) - 0.5 }
        var out = [Float](repeating: 0, count: mask.count)
        for start in mask.indices where mask[start] > 0 {
            var total: Float = 0
            for sign in [Float(1), -1] {
                var p = SIMD2(Float(start % width), Float(start / width))
                var dir = flow[start] * sign
                for _ in 0..<reach {
                    let x = Int(p.x), y = Int(p.y)
                    guard x >= 0, y >= 0, x < width, y < height else { break }
                    total += grain[(y / cell) * columns + x / cell]
                    var t = flow[y * width + x]
                    if t.x * dir.x + t.y * dir.y < 0 { t = -t }
                    dir = t
                    p += dir * 1.5
                }
            }
            out[start] = max(-1, min(1, total / Float(2 * reach).squareRoot() * 2.4))
        }
        return out
    }

    // MARK: Image operations

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Mean over a (2r+1)² window, edges clamped.
    static func box(_ v: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        var a = v, b = v
        let n = Float(2 * r + 1)
        for y in 0..<h {
            var sum: Float = 0
            for x in -r...r { sum += v[y * w + max(0, min(w - 1, x))] }
            for x in 0..<w {
                a[y * w + x] = sum / n
                sum += v[y * w + min(w - 1, x + r + 1)] - v[y * w + max(0, x - r)]
            }
        }
        for x in 0..<w {
            var sum: Float = 0
            for y in -r...r { sum += a[max(0, min(h - 1, y)) * w + x] }
            for y in 0..<h {
                b[y * w + x] = sum / n
                sum += a[min(h - 1, y + r + 1) * w + x] - a[max(0, y - r) * w + x]
            }
        }
        return b
    }

    /// He et al.'s guided filter: snaps a coarse mask to the edges of a full-resolution guide.
    private static func guidedFilter(guide I: [Float], input p: [Float], width w: Int, height h: Int, radius r: Int, eps: Float) -> [Float] {
        let n = I.count
        let meanI = box(I, width: w, height: h, radius: r), meanP = box(p, width: w, height: h, radius: r)
        let corrI = box((0..<n).map { I[$0] * I[$0] }, width: w, height: h, radius: r)
        let corrIP = box((0..<n).map { I[$0] * p[$0] }, width: w, height: h, radius: r)
        var a = [Float](repeating: 0, count: n), b = a
        for i in 0..<n {
            let variance = corrI[i] - meanI[i] * meanI[i]
            a[i] = (corrIP[i] - meanI[i] * meanP[i]) / (variance + eps)
            b[i] = meanP[i] - a[i] * meanI[i]
        }
        let meanA = box(a, width: w, height: h, radius: r), meanB = box(b, width: w, height: h, radius: r)
        return (0..<n).map { max(0, min(1, meanA[$0] * I[$0] + meanB[$0])) }
    }

    /// Fills pixels of weight 0 from their surroundings through an image pyramid.
    static func pullPush(_ pixels: [SIMD3<Float>], weights: [Float], width w: Int, height h: Int) -> [SIMD3<Float>] {
        guard w > 1 || h > 1 else { return pixels }
        let cw = max(1, w / 2), ch = max(1, h / 2)
        var colour = [SIMD3<Float>](repeating: .zero, count: cw * ch)
        var weight = [Float](repeating: 0, count: cw * ch)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x, c = min(ch - 1, y / 2) * cw + min(cw - 1, x / 2)
                colour[c] += pixels[i] * weights[i]
                weight[c] += weights[i]
            }
        }
        for i in colour.indices where weight[i] > 0 { colour[i] /= weight[i] }
        let scaled = weight.map { min(1, $0) }
        let coarse = pullPush(colour, weights: scaled, width: cw, height: ch)
        var out = pixels
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                // Bilinear lookup in the coarse level, so filled areas stay smooth.
                let u = Float(x) / 2 - 0.25, v = Float(y) / 2 - 0.25
                let x0 = max(0, min(cw - 1, Int(u))), y0 = max(0, min(ch - 1, Int(v)))
                let x1 = min(cw - 1, x0 + 1), y1 = min(ch - 1, y0 + 1)
                let fx = max(0, min(1, u - Float(x0))), fy = max(0, min(1, v - Float(y0)))
                let top = coarse[y0 * cw + x0] * (1 - fx) + coarse[y0 * cw + x1] * fx
                let bottom = coarse[y1 * cw + x0] * (1 - fx) + coarse[y1 * cw + x1] * fx
                let filled = top * (1 - fy) + bottom * fy
                out[i] = pixels[i] * weights[i] + filled * (1 - weights[i])
            }
        }
        return out
    }

    static func makeImage(_ pixels: [SIMD3<Float>], width w: Int, height h: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in pixels.indices {
            bytes[i * 4] = UInt8(max(0, min(255, pixels[i].x * 255)))
            bytes[i * 4 + 1] = UInt8(max(0, min(255, pixels[i].y * 255)))
            bytes[i * 4 + 2] = UInt8(max(0, min(255, pixels[i].z * 255)))
        }
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
    }

    private struct WarpField {
        let dx: [Float], dy: [Float]
        let width: Int, height: Int, step: Int

        func displacement(x: Int, y: Int) -> (Float, Float) {
            let u = Float(x) / Float(step), v = Float(y) / Float(step)
            let x0 = min(width - 2, Int(u)), y0 = min(height - 2, Int(v))
            let fx = u - Float(x0), fy = v - Float(y0)
            func lerp(_ a: [Float]) -> Float {
                let top = a[y0 * width + x0] * (1 - fx) + a[y0 * width + x0 + 1] * fx
                let bottom = a[(y0 + 1) * width + x0] * (1 - fx) + a[(y0 + 1) * width + x0 + 1] * fx
                return top * (1 - fy) + bottom * fy
            }
            return (lerp(dx), lerp(dy))
        }
    }

    /// An image drawn onto the canvas, as floats, with how much of each pixel it actually covers.
    private struct Raster {
        var pixels: [SIMD3<Float>]
        var coverage: [Float]
        var luminance: [Float] { pixels.map { 0.299 * $0.x + 0.587 * $0.y + 0.114 * $0.z } }

        /// The same picture with each canvas point taken from where `field` says it comes from.
        func warped(field: WarpField) -> Raster {
            var out = self
            let w = HairTryOn.width, h = HairTryOn.height
            for y in 0..<h {
                for x in 0..<w {
                    let (dx, dy) = field.displacement(x: x, y: y)
                    let sx = Float(x) - dx, sy = Float(y) - dy
                    let x0 = max(0, min(w - 2, Int(sx))), y0 = max(0, min(h - 2, Int(sy)))
                    let fx = max(0, min(1, sx - Float(x0))), fy = max(0, min(1, sy - Float(y0)))
                    let a = y0 * w + x0, b = a + 1, c = a + w, d = c + 1
                    let i = y * w + x
                    out.pixels[i] = (pixels[a] * (1 - fx) + pixels[b] * fx) * (1 - fy) + (pixels[c] * (1 - fx) + pixels[d] * fx) * fy
                    out.coverage[i] = (coverage[a] * (1 - fx) + coverage[b] * fx) * (1 - fy) + (coverage[c] * (1 - fx) + coverage[d] * fx) * fy
                }
            }
            return out
        }

        init?(_ image: CGImage, transform t: CGAffineTransform, width w: Int, height h: Int) {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
                guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                c.interpolationQuality = .high
                c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)        // canvas y down
                c.concatenate(t)
                c.translateBy(x: 0, y: CGFloat(image.height)); c.scaleBy(x: 1, y: -1)   // images draw y up
                c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else { return nil }
            pixels = [SIMD3<Float>](repeating: .zero, count: w * h)
            coverage = [Float](repeating: 0, count: w * h)
            for i in 0..<(w * h) {
                let a = Float(bytes[i * 4 + 3]) / 255
                coverage[i] = a
                guard a > 0 else { continue }
                pixels[i] = SIMD3(Float(bytes[i * 4]), Float(bytes[i * 4 + 1]), Float(bytes[i * 4 + 2])) / (255 * a)
            }
        }
    }
}

extension FaceMeasurement {
    /// Which way the head is turned and roughly how far; positive is towards the right of the picture, and a head
    /// facing the camera is near zero.
    var turn: Double {
        if let noseTurn { return noseTurn }
        // Older results: how far the mouth sits off the middle of the face's outline, which a hand or a collar
        // over the jaw throws off.
        let k = keyPoints
        let dx = k.pupilRight.x - k.pupilLeft.x, dy = k.pupilRight.y - k.pupilLeft.y
        let gap = max(1, hypot(dx, dy))
        let mid = CGPoint(x: (k.pupilLeft.x + k.pupilRight.x) / 2, y: (k.pupilLeft.y + k.pupilRight.y) / 2)
        func along(_ p: CGPoint) -> Double { Double(((p.x - mid.x) * dx + (p.y - mid.y) * dy) / gap) }
        let features = mouthCenter == .zero ? 0 : along(mouthCenter) / 2
        let left = along(k.cheekLeft), right = along(k.cheekRight)
        return (features - (left + right) / 2) / max(1, right - left)
    }
}
