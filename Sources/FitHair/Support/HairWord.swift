import CoreGraphics
import CoreText
import Foundation

/// The word combed out of hair: fine strands that run along each letter's strokes, computed from the
/// letter outlines. Each letter is rasterised, the direction of its strokes is read from the structure
/// tensor of its distance field, and strands are traced along that direction with a little wander.
struct HairWord: @unchecked Sendable {     // CGPath is immutable here
    struct Strand: Sendable {
        var points: [CGPoint]       // design units, y down
        var arrival: Double         // when it starts to grow, 0…1
        var glyph: Int              // which letter it belongs to
        var tone: Int               // index into `HairWord.tones`
        var fine: Bool              // thinner stroke
        var isLock = false          // part of a long lock that leaves the letters
    }

    /// Dark hair with a few lighter strands catching the light.
    static let tones: [UInt32] = [0x171513, 0x26221F, 0x3A342F, 0x6E6358]
    /// The design space is this wide; the height follows the word.
    static let designWidth: CGFloat = 1600

    let strands: [Strand]
    let size: CGSize
    /// Each letter's outline in design units, y down.
    let shapes: [CGPath]
    var glyphBounds: [CGRect] { shapes.map(\.boundingBoxOfPath) }

    /// Bodoni 72 Oldstyle Book Italic ships with every Mac, so nothing is bundled.
    static let fontName = "BodoniSvtyTwoOSITCTT-BookIt"

    static func make(text: String = "Plinth", fontName: String = HairWord.fontName, seed: UInt64 = 7) -> HairWord {
        let glyphs = outlines(text: text, fontName: fontName)
        let box = glyphs.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
        let s = designWidth / box.width
        var toDesign = CGAffineTransform(scaleX: s, y: -s).translatedBy(x: -box.minX, y: -box.maxY)
        let shapes = glyphs.compactMap { $0.copy(using: &toDesign) }

        var rng = SplitMix(state: seed)
        var all: [Strand] = []
        for (i, shape) in shapes.enumerated() {
            let order = Double(i) / Double(shapes.count)
            all += comb(shape, glyph: i, order: order, span: 1 / Double(shapes.count), rng: &rng)
        }
        all += locks(shapes: shapes, rng: &rng)
        return HairWord(strands: all, size: CGSize(width: designWidth, height: box.height * s), shapes: shapes)
    }

    // MARK: Long locks

    /// Two locks leave the word, each starting inside its letter so it grows out of the stroke without a seam:
    /// one continues the top serif of the P, one lifts away from the end of the h, the way a pen leaves the page.
    private static func locks(shapes: [CGPath], rng: inout SplitMix) -> [Strand] {
        guard shapes.count == 6 else { return [] }
        let p = shapes[0].boundingBoxOfPath, h = shapes[5].boundingBoxOfPath
        let top = CGPoint(x: p.minX + 205, y: p.minY + 11)
        // Starts inside the h's exit stroke and carries straight on through its tip, so there is no fork.
        let end = CGPoint(x: h.maxX - 39, y: h.maxY - 33)
        return lock(from: top, by: CGPoint(x: -115, y: -12), CGPoint(x: -225, y: -123), to: CGPoint(x: -80, y: -193),
                    count: 34, spread: 10, glyph: 0, arrival: 0, rng: &rng)
             + lock(from: end, by: CGPoint(x: 52, y: -26), CGPoint(x: 88, y: -82), to: CGPoint(x: 38, y: -170),
                    count: 40, spread: 11, glyph: 5, arrival: 0.93, rng: &rng)
    }

    /// A bundle of strands around one Bézier spine (control points relative to its start), narrowing to the tip.
    private static func lock(from p0: CGPoint, by c1: CGPoint, _ c2: CGPoint, to p3: CGPoint, count: Int, spread: CGFloat,
                             glyph: Int, arrival: Double, rng: inout SplitMix) -> [Strand] {
        (0..<count).map { n in
            let side = CGFloat(rng.unit() * 2 - 1), phase = CGFloat(rng.unit() * 6.28), reach = CGFloat(0.72 + rng.unit() * 0.28)
            let points: [CGPoint] = (0...48).map { k in
                let t = CGFloat(k) / 48 * reach, u = 1 - t
                let x = 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p3.x
                let y = 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p3.y
                let dx = 3 * u * u * c1.x + 6 * u * t * (c2.x - c1.x) + 3 * t * t * (p3.x - c2.x)
                let dy = 3 * u * u * c1.y + 6 * u * t * (c2.y - c1.y) + 3 * t * t * (p3.y - c2.y)
                let len = max(0.01, hypot(dx, dy))
                // No pinch where it leaves the letter: as wide as the thin stroke there, swelling a little, then to a point.
                let w = spread * (0.35 + 0.65 * sin(min(1, t * 3) * .pi / 2)) * pow(1 - t, 0.8) * side + 2.2 * sin(t * 9 + phase) * t
                return CGPoint(x: p0.x + x - dy / len * w, y: p0.y + y + dx / len * w)
            }
            return Strand(points: points, arrival: min(1, arrival + rng.unit() * 0.05), glyph: glyph,
                          tone: n % 7 == 0 ? 2 : 0, fine: n % 3 != 0, isLock: true)
        }
    }

    // MARK: Letter outlines

    private static func outlines(text: String, fontName: String) -> [CGPath] {
        let font = CTFontCreateWithName(fontName as CFString, 1000, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var result: [CGPath] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let n = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: n), origins = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &origins)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont   // CoreText always sets it on a run
            for i in 0..<n {
                guard let g = CTFontCreatePathForGlyph(runFont, ids[i], nil) else { continue }
                var move = CGAffineTransform(translationX: origins[i].x, y: origins[i].y)
                if let moved = g.copy(using: &move) { result.append(moved) }
            }
        }
        return result
    }

    // MARK: Combing one letter

    private static func comb(_ shape: CGPath, glyph: Int, order: Double, span: Double, rng: inout SplitMix) -> [Strand] {
        let bounds = shape.boundingBoxOfPath.insetBy(dx: -6, dy: -6).integral
        let w = Int(bounds.width), h = Int(bounds.height)
        guard w > 8, h > 8 else { return [] }

        // 1. Inside / outside.
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Bitmap row 0 is the last row CG draws, so flip to keep y down.
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
            ctx.addPath(shape); ctx.setFillColor(gray: 1, alpha: 1); ctx.fillPath()
        }
        let inside = bytes.map { $0 > 127 }
        let area = inside.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard area > 20 else { return [] }

        // 2. Chamfer distance to the outside.
        var d = inside.map { $0 ? Float(1e6) : Float(0) }
        let a: Float = 1, b: Float = 1.414
        for y in 1..<(h - 1) { for x in 1..<(w - 1) where inside[y * w + x] {
            let i = y * w + x
            d[i] = min(d[i], d[i - 1] + a, d[i - w] + a, d[i - w - 1] + b, d[i - w + 1] + b)
        } }
        for y in stride(from: h - 2, to: 0, by: -1) { for x in stride(from: w - 2, to: 0, by: -1) where inside[y * w + x] {
            let i = y * w + x
            d[i] = min(d[i], d[i + 1] + a, d[i + w] + a, d[i + w + 1] + b, d[i + w - 1] + b)
        } }

        // 3. Structure tensor of the distance field, smoothed so opposite sides of a stroke agree.
        var jxx = [Float](repeating: 0, count: w * h), jxy = jxx, jyy = jxx
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let i = y * w + x
            let gx = d[i + 1] - d[i - 1], gy = d[i + w] - d[i - w]
            jxx[i] = gx * gx; jxy[i] = gx * gy; jyy[i] = gy * gy
        } }
        for _ in 0..<2 { blur(&jxx, w, h, 5); blur(&jxy, w, h, 5); blur(&jyy, w, h, 5) }
        func tangent(_ i: Int) -> CGVector {
            let t = 0.5 * atan2(2 * jxy[i], jxx[i] - jyy[i]) + .pi / 2
            return CGVector(dx: CGFloat(cos(t)), dy: CGFloat(sin(t)))
        }

        // 4. Seeds, weighted towards thin strokes so hairlines are not left empty.
        var seeds: [Int] = []
        let target = Int(Double(area) * 0.013) + 26
        var tries = 0
        while seeds.count < target, tries < target * 400 {
            tries += 1
            let i = Int(rng.next(below: UInt64(w * h)))
            guard inside[i] else { continue }
            if rng.unit() < min(1, 3.2 / Double(d[i] + 0.5)) * 0.9 + 0.1 { seeds.append(i) }
        }

        // Small separate marks (the dot of the i) would come out as an empty ring: pack them.
        let small = Set(smallComponents(inside, w, h, maxArea: 1200))
        for i in small.sorted() where rng.unit() < 0.18 { seeds.append(i) }

        // 5. Trace.
        func isInside(_ p: CGPoint) -> Bool {
            let x = Int(p.x), y = Int(p.y)
            return x >= 0 && y >= 0 && x < w && y < h && inside[y * w + x]
        }
        func trace(from start: CGPoint, sign: CGFloat, steps: Int, wander: (amp: CGFloat, freq: CGFloat, phase: CGFloat), fly: Bool) -> [CGPoint] {
            let step: CGFloat = 2
            var p = start, out: [CGPoint] = []
            var i0 = Int(p.y) * w + Int(p.x)
            var dir = tangent(i0); dir = CGVector(dx: dir.dx * sign, dy: dir.dy * sign)
            var k = 0, flown = 0
            let flight = fly ? 14 + Int(rng.next(below: 30)) : 0
            var curl = CGFloat(rng.unit() - 0.5) * 0.035
            while k < steps {
                k += 1
                if isInside(p), flown == 0 {
                    i0 = Int(p.y) * w + Int(p.x)
                    var t = tangent(i0)
                    if t.dx * dir.dx + t.dy * dir.dy < 0 { t = CGVector(dx: -t.dx, dy: -t.dy) }
                    dir = CGVector(dx: dir.dx * 0.6 + t.dx * 0.4, dy: dir.dy * 0.6 + t.dy * 0.4)
                } else {
                    flown += 1
                    if flown > flight { break }
                    curl *= 1.01
                    let c = cos(curl), s = sin(curl)
                    dir = CGVector(dx: dir.dx * c - dir.dy * s, dy: dir.dx * s + dir.dy * c)
                }
                let len = max(0.001, hypot(dir.dx, dir.dy))
                dir = CGVector(dx: dir.dx / len, dy: dir.dy / len)
                let a = sin(CGFloat(k) * wander.freq + wander.phase) * wander.amp
                let c = cos(a), s = sin(a)
                let v = CGVector(dx: dir.dx * c - dir.dy * s, dy: dir.dx * s + dir.dy * c)
                p = CGPoint(x: p.x + v.dx * step, y: p.y + v.dy * step)
                out.append(p)
            }
            return out
        }

        var strands: [Strand] = []
        for i in seeds {
            let start = CGPoint(x: CGFloat(i % w) + 0.5, y: CGFloat(i / w) + 0.5)
            let wander = (amp: CGFloat(0.05 + rng.unit() * 0.14), freq: CGFloat(0.02 + rng.unit() * 0.05), phase: CGFloat(rng.unit() * 6.28))
            let forward = 40 + Int(rng.next(below: 130)), backward = 40 + Int(rng.next(below: 130))
            let fly = rng.unit() < 0.05
            let a = trace(from: start, sign: 1, steps: forward, wander: wander, fly: fly)
            let c = trace(from: start, sign: -1, steps: backward, wander: wander, fly: false)
            var line = Array(c.reversed()) + [start] + a
            guard line.count > (small.contains(i) ? 3 : 14) else { continue }
            // Keep every third sample: smooth enough at this scale, and a third of the drawing cost.
            line = stride(from: 0, to: line.count, by: 3).map { line[$0] } + [line[line.count - 1]]
            // Letters grow from their start: the end with the smaller x, then a little scatter.
            if line[0].x > line[line.count - 1].x { line.reverse() }
            let meanX = line.reduce(0) { $0 + $1.x } / CGFloat(line.count)
            let along = Double(meanX) / Double(max(1, w))
            let arrival = order + span * along * 0.85 + rng.unit() * 0.05
            let roll = rng.unit()
            let tone = roll < 0.42 ? 0 : (roll < 0.78 ? 1 : (roll < 0.95 ? 2 : 3))
            let offset = CGPoint(x: bounds.minX, y: bounds.minY)
            strands.append(Strand(points: line.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) },
                                  arrival: min(1, arrival), glyph: glyph, tone: tone, fine: fly || rng.unit() < 0.45))
        }
        return strands
    }

    /// Every pixel of the connected regions no larger than `maxArea`.
    private static func smallComponents(_ inside: [Bool], _ w: Int, _ h: Int, maxArea: Int) -> [Int] {
        var seen = [Bool](repeating: false, count: w * h), result: [Int] = []
        for start in inside.indices where inside[start] && !seen[start] {
            var stack = [start], region: [Int] = []
            seen[start] = true
            while let i = stack.popLast() {
                region.append(i)
                for n in [i - 1, i + 1, i - w, i + w] where n >= 0 && n < w * h && inside[n] && !seen[n] {
                    seen[n] = true; stack.append(n)
                }
            }
            if region.count <= maxArea { result += region }
        }
        return result
    }

    private static func blur(_ v: inout [Float], _ w: Int, _ h: Int, _ r: Int) {
        var out = v
        let n = Float(2 * r + 1)
        for y in 0..<h {
            var sum: Float = 0
            for x in -r...r { sum += v[y * w + min(w - 1, max(0, x))] }
            for x in 0..<w {
                out[y * w + x] = sum / n
                sum += v[y * w + min(w - 1, x + r + 1)] - v[y * w + max(0, x - r)]
            }
        }
        for x in 0..<w {
            var sum: Float = 0
            for y in -r...r { sum += out[min(h - 1, max(0, y)) * w + x] }
            for y in 0..<h {
                v[y * w + x] = sum / n
                sum += out[min(h - 1, y + r + 1) * w + x] - out[max(0, y - r) * w + x]
            }
        }
    }
}

/// The combed word baked to bitmaps once per run: the two halves that part around the bust, and the
/// growth cut into thin slices of time. Showing the slices one after another grows every strand along its
/// length at full frame rate; stroking ~1800 strands live takes over 100 ms a frame.
struct HairWordArt: @unchecked Sendable {
    /// Room around the word for stray hairs, in design units.
    static let pad: CGFloat = 240
    /// Multiply the word's intended width by this to size the padded images.
    static var paddedScale: CGFloat { (HairWord.designWidth + 2 * pad) / HairWord.designWidth }

    /// One moment of the growth: the short pieces of strand laid down then.
    struct Slice {
        let image: CGImage
        let frame: CGRect       // within the padded word, 0…1, y down
        let time: Double        // 0…1
    }
    /// Holds the slices so they can be dropped once the opening has played.
    final class Growth: @unchecked Sendable {
        var slices: [Slice]
        init(_ slices: [Slice]) { self.slices = slices }
    }

    let growth: Growth
    let aspect: CGFloat

    /// A bitmap cropped to what it contains, and where it belongs within the padded word (0…1, y down).
    struct Placed: @unchecked Sendable {
        let image: CGImage
        let frame: CGRect
    }

    /// The word as loose hair for the opening, then as the finished lettering: solid letters with combed
    /// strands and bands of shine inside them, and the two long locks on their own so they can move.
    final class Finished: @unchecked Sendable {
        private(set) var left: Placed?, right: Placed?
        let leftType: Placed, rightType: Placed, leftLock: Placed, rightLock: Placed
        /// Where each lock joins its letter, as a fraction of the lock's own image.
        let leftLockRoot: CGPoint, rightLockRoot: CGPoint

        init(left: Placed, right: Placed, leftType: Placed, rightType: Placed, leftLock: Placed, rightLock: Placed,
             leftLockRoot: CGPoint, rightLockRoot: CGPoint) {
            self.left = left; self.right = right
            self.leftType = leftType; self.rightType = rightType
            self.leftLock = leftLock; self.rightLock = rightLock
            self.leftLockRoot = leftLockRoot; self.rightLockRoot = rightLockRoot
        }

        /// The loose-hair letters are only seen during the opening.
        func releaseLooseHair() { left = nil; right = nil }
    }

    private static let combed = Reloadable { HairWord.make() }
    /// Only what the growth needs, so the opening can begin almost at once.
    private static let sharedArt = Reloadable { () -> HairWordArt in
        let word = await combed.value.value
        let size = paddedSize(word)
        return HairWordArt(growth: Growth(slices(word, size: size)), aspect: size.width / size.height)
    }
    /// Ready well before the growth ends.
    private static let finishedArt = Reloadable { () -> Finished? in
        let word = await combed.value.value
        return renderFinished(word, size: paddedSize(word))
    }
    static var shared: Task<HairWordArt, Never> { sharedArt.value }
    static var finished: Task<Finished?, Never> { finishedArt.value }

    /// For when the app stays in the menu bar with no window open.
    static func releaseArtwork() {
        combed.release(); sharedArt.release(); finishedArt.release()
    }

    /// Letters up to this index stay on the left of the bust.
    private static let lastLeftGlyph = 2
    /// Each strand takes this share of the whole growth to reach its tip.
    private static let strandGrowth = 0.28
    private static let sliceCount = 40

    private static func paddedSize(_ word: HairWord) -> CGSize {
        CGSize(width: word.size.width + 2 * pad, height: word.size.height + 2 * pad)
    }

    private static func renderFinished(_ word: HairWord, size: CGSize) -> Finished? {
        let leftGlyphs = 0...lastLeftGlyph, rightGlyphs = (lastLeftGlyph + 1)...(word.shapes.count - 1)
        guard let left = paint(word, size: size, where: { leftGlyphs.contains($0.glyph) && !$0.isLock }),
              let right = paint(word, size: size, where: { rightGlyphs.contains($0.glyph) && !$0.isLock }),
              let leftType = lettering(word, size: size, glyphs: leftGlyphs),
              let rightType = lettering(word, size: size, glyphs: rightGlyphs),
              let leftLock = locks(word, size: size, glyphs: leftGlyphs),
              let rightLock = locks(word, size: size, glyphs: rightGlyphs) else { return nil }
        func root(_ glyphs: ClosedRange<Int>, in lock: Placed) -> CGPoint {
            guard let start = word.strands.first(where: { $0.isLock && glyphs.contains($0.glyph) })?.points.first else { return CGPoint(x: 0.5, y: 0.5) }
            return CGPoint(x: ((start.x + pad) / size.width - lock.frame.minX) / lock.frame.width,
                           y: ((start.y + pad) / size.height - lock.frame.minY) / lock.frame.height)
        }
        return Finished(left: left, right: right, leftType: leftType, rightType: rightType, leftLock: leftLock, rightLock: rightLock,
                        leftLockRoot: root(leftGlyphs, in: leftLock), rightLockRoot: root(rightGlyphs, in: rightLock))
    }

    /// Draws into a bitmap just big enough for `box` (design units): a full-word canvas per layer costs ~20 MB each.
    private static func placed(box: CGRect, size: CGSize, draw: (CGContext) -> Void) -> Placed? {
        let k: CGFloat = 1.6        // sharp at full screen on a large display
        let b = box.insetBy(dx: -3, dy: -3).integral
        guard !b.isNull, b.width > 0, b.height > 0,
              let c = CGContext(data: nil, width: Int(b.width * k), height: Int(b.height * k), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.translateBy(x: 0, y: CGFloat(c.height)); c.scaleBy(x: k, y: -k); c.translateBy(x: -b.minX, y: -b.minY)
        c.setLineCap(.round); c.setLineJoin(.round)
        draw(c)
        guard let image = c.makeImage() else { return nil }
        return Placed(image: image, frame: CGRect(x: (b.minX + pad) / size.width, y: (b.minY + pad) / size.height,
                                                  width: b.width / size.width, height: b.height / size.height))
    }

    private static func bounds(of strands: [HairWord.Strand]) -> CGRect {
        let points = strands.flatMap(\.points)
        guard let x0 = points.map(\.x).min(), let x1 = points.map(\.x).max(),
              let y0 = points.map(\.y).min(), let y1 = points.map(\.y).max() else { return .null }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private static func colour(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    private static func paint(_ word: HairWord, size: CGSize, where keep: (HairWord.Strand) -> Bool) -> Placed? {
        let chosen = word.strands.filter(keep)
        return placed(box: bounds(of: chosen), size: size) { c in
            for tone in 0..<HairWord.tones.count {
                for fine in [false, true] {
                    let path = CGMutablePath()
                    for s in chosen where s.tone == tone && s.fine == fine { path.addLines(between: s.points) }
                    c.addPath(path)
                    c.setStrokeColor(colour(HairWord.tones[tone]))
                    c.setLineWidth(fine ? 0.81 : 1.44)
                    c.strokePath()
                }
            }
        }
    }

    private static func colour(_ hex: UInt32, alpha: CGFloat) -> CGColor {
        colour(hex).copy(alpha: alpha) ?? colour(hex)
    }

    private static func lettering(_ word: HairWord, size: CGSize, glyphs: ClosedRange<Int>) -> Placed? {
        let letters = CGMutablePath()
        for i in glyphs { letters.addPath(word.shapes[i]) }
        return placed(box: letters.boundingBoxOfPath, size: size) { c in
            c.addPath(letters); c.setFillColor(colour(0x14110E)); c.fillPath()

            // Strands inside the letters. The lighter ones brighten in soft bands that run across the strokes,
            // the way shine sits on combed hair; along the italic slant a whole stem would light up at once.
            let looks: [(hex: UInt32, alpha: CGFloat, width: CGFloat)] =
                [(0x000000, 0.7, 1.4), (0x4A4036, 0.8, 1.1), (0x7D6F60, 0.75, 0.9), (0xB5A491, 0.7, 0.8)]
            c.addPath(letters); c.clip()
            for s in word.strands where glyphs.contains(s.glyph) && !s.isLock {
                let look = looks[s.tone]
                c.setLineWidth(look.width)
                var i = 0
                while i < s.points.count - 1 {
                    let j = min(s.points.count - 1, i + 4)
                    let band = 0.5 + 0.5 * sin((s.points[i].x * 0.37 - s.points[i].y * 0.93) / 44)
                    let alpha = s.tone == 0 ? look.alpha : look.alpha * (0.12 + 0.88 * pow(band, 3))
                    c.setStrokeColor(colour(look.hex, alpha: alpha))
                    c.addLines(between: Array(s.points[i...j]))
                    c.strokePath()
                    i = j
                }
            }
        }
    }

    private static func locks(_ word: HairWord, size: CGSize, glyphs: ClosedRange<Int>) -> Placed? {
        let strands = word.strands.filter { glyphs.contains($0.glyph) && $0.isLock }
        return placed(box: bounds(of: strands), size: size) { c in
            for s in strands {
                c.setStrokeColor(colour(s.tone == 0 ? 0x14110E : 0x5A4E43, alpha: 0.9))
                c.setLineWidth(s.fine ? 0.75 : 1.15)
                c.addLines(between: s.points)
                c.strokePath()
            }
        }
    }

    private static func slices(_ word: HairWord, size: CGSize) -> [Slice] {
        // paths[slice][tone * 2 + (fine ? 1 : 0)]
        let kinds = HairWord.tones.count * 2
        let paths = (0..<sliceCount).map { _ in (0..<kinds).map { _ in CGMutablePath() } }
        for s in word.strands {
            let n = s.points.count
            let kind = s.tone * 2 + (s.fine ? 1 : 0)
            for i in 0..<(n - 1) {
                let along = (Double(i) + 0.5) / Double(n - 1)
                let time = s.arrival * (1 - strandGrowth) + along * strandGrowth
                let index = min(sliceCount - 1, Int(time * Double(sliceCount)))
                paths[index][kind].addLines(between: [s.points[i], s.points[i + 1]])
            }
        }
        let k: CGFloat = 1.25       // softer than the finished word, and only seen while it is moving
        var result: [Slice] = []
        for (index, group) in paths.enumerated() {
            let box = group.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }.insetBy(dx: -2, dy: -2).integral
            guard !box.isNull, box.width > 0,
                  let c = CGContext(data: nil, width: Int(box.width * k), height: Int(box.height * k), bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            c.translateBy(x: 0, y: CGFloat(c.height)); c.scaleBy(x: k, y: -k); c.translateBy(x: -box.minX, y: -box.minY)
            c.setLineCap(.round); c.setLineJoin(.round)
            for (kind, path) in group.enumerated() where !path.isEmpty {
                c.addPath(path)
                c.setStrokeColor(colour(HairWord.tones[kind / 2]))
                c.setLineWidth(kind % 2 == 1 ? 0.81 : 1.44)
                c.strokePath()
            }
            guard let image = c.makeImage() else { continue }
            let frame = CGRect(x: (box.minX + pad) / size.width, y: (box.minY + pad) / size.height,
                               width: box.width / size.width, height: box.height / size.height)
            result.append(Slice(image: image, frame: frame, time: Double(index) / Double(sliceCount)))
        }
        return result
    }
}

/// Small deterministic generator, so the word is combed the same way on every launch.
struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(below n: UInt64) -> UInt64 { next() % max(1, n) }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
