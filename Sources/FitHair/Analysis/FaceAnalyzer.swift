import Foundation
import CoreGraphics
import Vision

/// Key points used for the face-shape decision, in image pixel coordinates (origin top-left).
struct KeyPoints: Equatable, Codable {
    var hairline: CGPoint      // ① estimated
    var chin: CGPoint          // ②
    var foreheadLeft: CGPoint  // ③ estimated
    var foreheadRight: CGPoint // ④ estimated
    var cheekLeft: CGPoint     // ⑤
    var cheekRight: CGPoint    // ⑥
    var jawLeft: CGPoint       // ⑦
    var jawRight: CGPoint      // ⑧
    var pupilLeft: CGPoint     // ⑨
    var pupilRight: CGPoint    // ⑩
}

struct FaceMeasurement: Equatable, Codable {
    var imageSize: CGSize
    /// Every Vision landmark, image pixels, origin top-left.
    var allPoints: [CGPoint]
    var keyPoints: KeyPoints
    /// Widths and length in pixels, measured after levelling the eyes.
    var foreheadWidth: Double
    var cheekWidth: Double
    var jawWidth: Double
    var faceLength: Double
    var jawAngle: Double
    /// Head roll and yaw in degrees (yaw is nil when Vision doesn't report it).
    var roll: Double
    var yaw: Double?
    var pitch: Double? = nil
    /// How far the tip of the nose sits to the right of the midpoint between the pupils, along the line of the eyes,
    /// as a share of the distance between them: which way the head is turned, and roughly how much. Vision's yaw
    /// comes in steps too coarse to tell. nil in results saved before this was measured.
    var noseTurn: Double? = nil
    /// The line of the eyebrows: its left end, middle and right end, image pixels. Absent in results saved before
    /// it was recorded.
    var brows: [CGPoint]? = nil
    var ratios: FaceRatios
    /// Centre of the mouth (used to sanity-check the jaw position).
    var mouthCenter: CGPoint = .zero
    /// Vision's face contour (ear to ear around the chin), image pixels, origin top-left.
    var contour: [CGPoint] = []
    /// How many frames were combined (median) — 1 for a single photo.
    var sampleCount: Int = 1
    /// Which input frame the drawn points come from (the one closest to the median).
    var frameIndex: Int = 0
    /// Frame-to-frame spread (max − min) of each ratio when several frames were combined.
    var spread: FaceRatios?
    /// Found on the hair segmentation (true) or estimated from proportions (false).
    var hairlineMeasured = false
    var foreheadMeasured = false
    /// Hair (bangs) was covering the forehead, so hairline and forehead had to be estimated.
    var foreheadCovered = false
    /// Other, smaller faces in the photo; the largest one is measured.
    var otherFaces = 0
    /// Part of the face outline falls outside the photo, so Vision guessed it.
    var faceCutOff = false

    /// Below this many pixels across the cheekbones the outline is too coarse to measure.
    static let minimumCheekWidth = 100.0
    var faceTooSmall: Bool { cheekWidth < Self.minimumCheekWidth }
    /// Beyond this the head is too far over for the (upright) hair segmentation and the levelling to hold.
    static let maximumRoll = 20.0
    var tiltedTooFar: Bool { abs(roll) > Self.maximumRoll }

    var warnings: [String] {
        var w: [String] = []
        if faceTooSmall { w.append("脸在照片里太小或太模糊，量不准。请靠近一点，或换一张清晰的照片。") }
        if faceCutOff { w.append("脸有一部分在画面外，那部分是估算的。请把整张脸拍进去。") }
        if otherFaces > 0 { w.append("照片里有 \(otherFaces + 1) 张脸，量的是最大的那张。") }
        if let yaw, abs(yaw) > 12 { w.append("头偏转了约 \(Int(abs(yaw).rounded()))°，结果可能不准，建议正对镜头重拍。") }
        if let pitch, abs(pitch) > 12 { w.append("抬头或低头的幅度较大，建议平视镜头重拍。") }
        if tiltedTooFar {
            w.append("头歪了约 \(Int(abs(roll).rounded()))°，量不准。请摆正再拍。")
        } else if abs(roll) > 10 {
            w.append("头歪了约 \(Int(abs(roll).rounded()))°，已自动校正。")
        }
        if foreheadCovered { w.append("刘海挡住了额头，额头宽度和脸长是估算的。把刘海撩起来再拍会更准。") }
        return w
    }
}

enum FaceAnalysisError: LocalizedError, Equatable {
    case noFace, upsideDown
    case landmarksMissing

    var errorDescription: String? {
        switch self {
        case .noFace: "没有找到人脸。请用一张正脸、光线充足的照片。"
        case .upsideDown: "这张照片里的脸好像是倒着的，转正后再试一次。"
        case .landmarksMissing: "找到了人脸，但看不清轮廓。请把头发撩到耳后，露出额头和下颌线再试一次。"
        }
    }
}

enum FaceAnalyzer {
    /// Runs Apple Vision on-device and measures the face.
    static func analyze(_ image: CGImage) throws -> FaceMeasurement {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3    // the point layout everything below was tuned on
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        guard let faces = request.results, !faces.isEmpty else { throw FaceAnalysisError.noFace }
        let face = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }!
        guard let lm = face.landmarks else { throw FaceAnalysisError.landmarksMissing }

        let size = CGSize(width: image.width, height: image.height)
        func pts(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: size.height - $0.y) }
        }

        let rawContour = pts(lm.faceContour)
        let browL = pts(lm.leftEyebrow), browR = pts(lm.rightEyebrow)
        let nose = pts(lm.nose)
        let eyeL = pts(lm.leftEye), eyeR = pts(lm.rightEye)
        var pupilL = pts(lm.leftPupil).first ?? centroid(eyeL)
        var pupilR = pts(lm.rightPupil).first ?? centroid(eyeR)
        guard rawContour.count >= 13, !browL.isEmpty, !browR.isEmpty, !nose.isEmpty, pupilL != .zero, pupilR != .zero else {
            throw FaceAnalysisError.landmarksMissing
        }
        if pupilL.x > pupilR.x { swap(&pupilL, &pupilR) }   // keep "left" = image left

        // Vision's contour is a model estimate that can sit inside or outside the real face edge.
        // Pull each point onto the strongest nearby edge in the photo so lines hug the silhouette.
        let gray = GrayImage(image)
        let contour = snapContour(rawContour, gray: gray)

        let lips = pts(lm.outerLips)
        let mouth = centroid(lips.isEmpty ? pts(lm.innerLips) : lips)
        let all = [lm.faceContour, lm.leftEye, lm.rightEye, lm.leftEyebrow, lm.rightEyebrow, lm.nose, lm.noseCrest,
                   lm.medianLine, lm.outerLips, lm.innerLips, lm.leftPupil, lm.rightPupil].flatMap { pts($0) }

        // Level the eyes so widths are horizontal.
        let rollRad = atan2(Double(pupilR.y - pupilL.y), Double(pupilR.x - pupilL.x))
        let center = CGPoint(x: (pupilL.x + pupilR.x) / 2, y: (pupilL.y + pupilR.y) / 2)
        let level = { (p: CGPoint) in rotate(p, around: center, by: -rollRad) }
        let back = { (p: CGPoint) in rotate(p, around: center, by: rollRad) }

        // Vision's nose crest runs down the ridge to the tip and ends with the two wings of the nose; without it,
        // the lowest points of the nose stand in for the tip.
        let crest = pts(lm.noseCrest).map(level)
        let lowest = nose.map(level).sorted { $0.y > $1.y }.prefix(max(1, nose.count / 3))
        let tip = crest.count >= 4 ? crest[crest.count - 3] : CGPoint(x: lowest.map(\.x).reduce(0, +) / CGFloat(lowest.count), y: 0)
        let noseTurn = Double((tip.x - center.x) / max(1, hypot(pupilR.x - pupilL.x, pupilR.y - pupilL.y)))

        let c = contour.map(level)
        let ci = c.indices.max { c[$0].y < c[$1].y }!          // chin = lowest contour point
        func at(_ i: Int) -> CGPoint { c[min(max(i, 0), c.count - 1)] }
        let span = min(ci, c.count - 1 - ci)
        // The cheekbone point sits seven eighths of the way from the chin to the ear, however many points there are.
        let cheekOff = min(span, Int((Double(span) * 0.875).rounded()))
        let cheekA = at(ci - cheekOff), cheekB = at(ci + cheekOff)
        let chinPoint = c[ci]
        // Jaw corner (gonion): on the smooth contour between the cheekbone point and the chin,
        // the point farthest from the straight cheek→chin line — the corner of the "L".
        let jawA = jawCorner(Array(c[(ci - cheekOff)...ci]))
        let jawB = jawCorner(Array(c[ci...(ci + cheekOff)].reversed()))
        _ = chinPoint

        let brows = (browL + browR).map(level)
        let browY = brows.map(\.y).reduce(0, +) / Double(brows.count)
        let noseBaseY = nose.map(level).map(\.y).max()!
        let third = noseBaseY - browY
        let browMinX = brows.map(\.x).min()!, browMaxX = brows.map(\.x).max()!
        let browMid = (browMinX + browMaxX) / 2
        let chin = c[ci]
        let cheekSpan = abs(cheekB.x - cheekA.x)
        guard chin.y > browY else { throw FaceAnalysisError.upsideDown }

        // Hairline and forehead edges, measured on a hair / face-skin segmentation of the head.
        // Falls back to proportions when they can't be seen (factors set to agree with the segmentation
        // on the reference busts: hairline ≈ 0.9 of a facial third above the brows, forehead ≈ brow span).
        var hairlineY = browY - third * 0.9
        var foreheadL = browMid - (browMaxX - browMinX) * 0.5
        var foreheadR = browMid + (browMaxX - browMinX) * 0.5
        var foreheadY = (hairlineY + browY) / 2
        var hairlineMeasured = false, foreheadMeasured = false, foreheadCovered = false
        let cropSide = max(third * 5.2, cheekSpan * 2.3)
        let cropCenter = back(CGPoint(x: browMid, y: ((browY - third * 2.7) + (chin.y + third * 0.4)) / 2))
        if let mask = HairSegmenter.segment(image, crop: CGRect(x: cropCenter.x - cropSide / 2, y: cropCenter.y - cropSide / 2,
                                                               width: cropSide, height: cropSide)) {
            let edge = SkinEdge(mask: mask, toImage: back, step: max(1, third * 0.02))
            // Hairline: walk up three columns of forehead and take the middle answer.
            let columns = [-0.08, 0, 0.08].compactMap { dx in
                edge.walk(from: CGPoint(x: browMid + cheekSpan * dx, y: browY - third * 0.25), dx: 0, dy: -1, limit: third * 2.4)
            }
            let hits = columns.filter { $0.label == .hair }.map(\.point.y).sorted()
            if hits.count >= 2 {
                let y = hits[hits.count / 2]
                if y < browY - third * 0.55 { hairlineY = y; hairlineMeasured = true } else { foreheadCovered = true }
            } else if columns.isEmpty {
                foreheadCovered = true   // no forehead skin right above the brows
            }
            // Forehead width: across the forehead, a little under halfway up to the hairline.
            foreheadY = browY - (browY - hairlineY) * 0.4
            let rows = [-0.05, 0, 0.05].compactMap { dy -> (CGFloat, CGFloat)? in
                let start = CGPoint(x: browMid, y: foreheadY + third * dy)
                guard let l = edge.walk(from: start, dx: -1, dy: 0, limit: cheekSpan * 0.75),
                      let r = edge.walk(from: start, dx: 1, dy: 0, limit: cheekSpan * 0.75) else { return nil }
                return (l.point.x, r.point.x)
            }
            if rows.count >= 2, !foreheadCovered {
                let ls = rows.map(\.0).sorted(), rs = rows.map(\.1).sorted()
                let l = ls[ls.count / 2], r = rs[rs.count / 2]
                if (0.55...1.3).contains((r - l) / cheekSpan) { foreheadL = l; foreheadR = r; foreheadMeasured = true }
            }
        }
        let foreheadWidth = Double(foreheadR - foreheadL)

        let cheekWidth = Double(abs(cheekB.x - cheekA.x))
        let jawWidth = Double(abs(jawB.x - jawA.x))
        let faceLength = Double(chin.y - hairlineY)

        func angle(at g: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            let v1 = CGVector(dx: a.x - g.x, dy: a.y - g.y), v2 = CGVector(dx: b.x - g.x, dy: b.y - g.y)
            let dot = Double(v1.dx * v2.dx + v1.dy * v2.dy)
            let n = Double(hypot(v1.dx, v1.dy) * hypot(v2.dx, v2.dy))
            return n > 0 ? acos(max(-1, min(1, dot / n))) * 180 / .pi : 180
        }
        // Frontal jaw angle: cheekbone point → jaw corner → chin. Smaller = more angular jaw.
        let angA = angle(at: jawA, cheekA, chin)
        let angB = angle(at: jawB, cheekB, chin)
        let jawAngle = (angA + angB) / 2

        let widest = max(foreheadWidth, cheekWidth, jawWidth)
        let ratios = FaceRatios(lengthToWidth: faceLength / widest,
                                foreheadToCheek: foreheadWidth / cheekWidth,
                                jawToCheek: jawWidth / cheekWidth,
                                jawAngle: jawAngle)

        guard [ratios.lengthToWidth, ratios.foreheadToCheek, ratios.jawToCheek, ratios.jawAngle].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw FaceAnalysisError.landmarksMissing
        }

        let leftFirst = { (a: CGPoint, b: CGPoint) in a.x <= b.x ? (a, b) : (b, a) }
        let (cl, cr) = leftFirst(cheekA, cheekB)
        let (jl, jr) = leftFirst(jawA, jawB)
        let keys = KeyPoints(
            hairline: back(CGPoint(x: browMid, y: hairlineY)),
            chin: back(chin),
            foreheadLeft: back(CGPoint(x: foreheadL, y: foreheadY)),
            foreheadRight: back(CGPoint(x: foreheadR, y: foreheadY)),
            cheekLeft: back(cl), cheekRight: back(cr),
            jawLeft: back(jl), jawRight: back(jr),
            pupilLeft: pupilL, pupilRight: pupilR)

        return FaceMeasurement(imageSize: size, allPoints: all, keyPoints: keys,
                               foreheadWidth: foreheadWidth, cheekWidth: cheekWidth, jawWidth: jawWidth,
                               faceLength: faceLength, jawAngle: jawAngle,
                               roll: rollRad * 180 / .pi,
                               yaw: face.yaw.map { $0.doubleValue * 180 / .pi },
                               pitch: face.pitch.map { $0.doubleValue * 180 / .pi },
                               noseTurn: noseTurn,
                               brows: [browMinX, browMid, browMaxX].map { back(CGPoint(x: $0, y: browY)) },
                               ratios: ratios,
                               mouthCenter: mouth,
                               contour: contour,
                               hairlineMeasured: hairlineMeasured,
                               foreheadMeasured: foreheadMeasured,
                               foreheadCovered: foreheadCovered,
                               otherFaces: faces.count - 1,
                               faceCutOff: rawContour.contains { !CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1).contains($0) })
    }

    /// Measures several frames of the same face and combines them with the median, which removes most of the
    /// frame-to-frame jitter of a single photo. Frames where no face is found are skipped.
    static func analyze(frames: [CGImage]) throws -> FaceMeasurement {
        var results: [FaceMeasurement] = []
        var origin: [Int] = []
        var lastError: Error = FaceAnalysisError.noFace
        for (i, f) in frames.enumerated() {
            do { results.append(try analyze(f)); origin.append(i) } catch { lastError = error }
        }
        guard !results.isEmpty, results.count * 2 >= frames.count else { throw lastError }
        func median(_ v: [Double]) -> Double {
            let s = v.sorted(); let m = s.count / 2
            return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
        }
        let r = results.map(\.ratios)
        let med = FaceRatios(lengthToWidth: median(r.map(\.lengthToWidth)),
                             foreheadToCheek: median(r.map(\.foreheadToCheek)),
                             jawToCheek: median(r.map(\.jawToCheek)),
                             jawAngle: median(r.map(\.jawAngle)))
        func range(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
        let spread = FaceRatios(lengthToWidth: range(r.map(\.lengthToWidth)),
                                foreheadToCheek: range(r.map(\.foreheadToCheek)),
                                jawToCheek: range(r.map(\.jawToCheek)),
                                jawAngle: range(r.map(\.jawAngle)))
        // Show the frame closest to the median so the drawn lines match the numbers.
        func dist(_ x: FaceRatios) -> Double {
            abs(x.lengthToWidth - med.lengthToWidth) / 0.12 + abs(x.foreheadToCheek - med.foreheadToCheek) / 0.06
                + abs(x.jawToCheek - med.jawToCheek) / 0.07 + abs(x.jawAngle - med.jawAngle) / 12
        }
        let bestIndex = results.indices.min { dist(results[$0].ratios) < dist(results[$1].ratios) }!
        var best = results[bestIndex]
        best.ratios = med
        best.sampleCount = results.count
        best.spread = spread
        best.frameIndex = origin[bestIndex]
        return best
    }

    /// Moves every contour point along its normal to the strongest brightness edge nearby,
    /// then median-filters the moves so one bad jump can't bend the outline.
    static func snapContour(_ c: [CGPoint], gray: GrayImage) -> [CGPoint] {
        guard c.count >= 5 else { return c }
        let xs = c.map(\.x)
        let faceW = Double((xs.max() ?? 0) - (xs.min() ?? 0))
        let center = CGPoint(x: (xs.max()! + xs.min()!) / 2, y: c.map(\.y).reduce(0, +) / CGFloat(c.count) - CGFloat(faceW) * 0.2)
        let reach = max(4, faceW * 0.07)
        var offsets: [Double] = []
        var normals: [CGVector] = []
        for i in c.indices {
            let a = c[max(i - 1, 0)], b = c[min(i + 1, c.count - 1)]
            var n = CGVector(dx: -(b.y - a.y), dy: b.x - a.x)
            let len = max(hypot(n.dx, n.dy), 1e-6)
            n = CGVector(dx: n.dx / len, dy: n.dy / len)
            // point the normal outward, away from the face centre
            if (c[i].x - center.x) * n.dx + (c[i].y - center.y) * n.dy < 0 { n = CGVector(dx: -n.dx, dy: -n.dy) }
            normals.append(n)
            // near the ears (top two points on each side) only allow small outward moves
            let nearEar = i < 2 || i >= c.count - 2
            let outReach = nearEar ? reach * 0.3 : reach
            var best = 0.0, bestScore = -Double.infinity
            var t = -reach
            while t <= outReach {
                let p = CGPoint(x: c[i].x + n.dx * CGFloat(t), y: c[i].y + n.dy * CGFloat(t))
                let score = gray.edge(at: p, along: n) * (1 - 0.5 * abs(t) / reach)
                if score > bestScore { bestScore = score; best = t }
                t += 1
            }
            offsets.append(best)
        }
        // median of 5 drops outliers, then a short average keeps the outline smooth
        let med = offsets.indices.map { i -> Double in
            let w = (-2...2).map { offsets[min(max(i + $0, 0), offsets.count - 1)] }.sorted()
            return w[2]
        }
        let smooth = med.indices.map { i -> Double in
            (med[max(i - 1, 0)] + 2 * med[i] + med[min(i + 1, med.count - 1)]) / 4
        }
        return c.indices.map { i in
            CGPoint(x: c[i].x + normals[i].dx * CGFloat(smooth[i]), y: c[i].y + normals[i].dy * CGFloat(smooth[i]))
        }
    }

    /// `side` runs from the cheekbone point to the chin. Returns the jaw corner on a smoothed curve.
    static func jawCorner(_ side: [CGPoint]) -> CGPoint {
        guard side.count >= 3 else { return side.first ?? .zero }
        let dense = catmullRom(side, samplesPerSegment: 12)
        let a = side.first!, b = side.last!
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let len = max(hypot(dx, dy), 1e-6)
        // Ignore the last 20 % next to the chin, where the chin's own curve lives.
        let usable = dense.prefix(Int(Double(dense.count) * 0.8))
        return usable.max { distance($0) < distance($1) } ?? side[side.count / 2]
        func distance(_ p: CGPoint) -> Double { abs(Double(p.x - a.x) * dy - Double(p.y - a.y) * dx) / len }
    }

    /// Smooth curve through the points (centripetal-ish Catmull–Rom with clamped ends).
    static func catmullRom(_ p: [CGPoint], samplesPerSegment n: Int) -> [CGPoint] {
        guard p.count >= 2 else { return p }
        var out: [CGPoint] = []
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            for k in 0..<n {
                let t = CGFloat(k) / CGFloat(n), t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
                out.append(CGPoint(x: x, y: y))
            }
        }
        out.append(p.last!)
        return out
    }

    private static func centroid(_ p: [CGPoint]) -> CGPoint {
        guard !p.isEmpty else { return .zero }
        return CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
    }

    private static func rotate(_ p: CGPoint, around c: CGPoint, by a: Double) -> CGPoint {
        let dx = Double(p.x - c.x), dy = Double(p.y - c.y)
        return CGPoint(x: Double(c.x) + dx * cos(a) - dy * sin(a), y: Double(c.y) + dx * sin(a) + dy * cos(a))
    }
}


/// 8-bit grayscale copy of a photo for edge sampling (row 0 = top of the image).
struct GrayImage {
    let width: Int, height: Int
    private let px: [UInt8]

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        width = w; height = h
        px = buf
    }

    /// Bilinear sample, 0…255.
    func at(_ x: Double, _ y: Double) -> Double {
        let x = min(max(x, 0), Double(width - 1)), y = min(max(y, 0), Double(height - 1))
        let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = x - Double(x0), fy = y - Double(y0)
        let a = Double(px[y0 * width + x0]), b = Double(px[y0 * width + x1])
        let c = Double(px[y1 * width + x0]), d = Double(px[y1 * width + x1])
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// Strength of a brightness edge crossing direction `n` at `p`, averaged a little along the edge.
    func edge(at p: CGPoint, along n: CGVector) -> Double {
        let step = max(2.0, Double(width) / 400)
        var total = 0.0
        for k in -2...2 {
            let tx = -Double(n.dy) * Double(k) * step, ty = Double(n.dx) * Double(k) * step
            let x = Double(p.x) + tx, y = Double(p.y) + ty
            let ahead = at(x + Double(n.dx) * step, y + Double(n.dy) * step)
            let behind = at(x - Double(n.dx) * step, y - Double(n.dy) * step)
            total += abs(ahead - behind)
        }
        return total / 5
    }
}

/// Walks across the segmentation from a point on the face and reports where face skin ends for good.
struct SkinEdge {
    let mask: HairSegmenter.Mask
    let toImage: (CGPoint) -> CGPoint
    let step: CGFloat

    struct Hit { let point: CGPoint; let label: HairSegmenter.Label }

    /// `from` and the result are in levelled coordinates. Returns nil if `from` isn't on face skin.
    func walk(from start: CGPoint, dx: CGFloat, dy: CGFloat, limit: CGFloat) -> Hit? {
        guard mask.label(at: toImage(start)) == .faceSkin else { return nil }
        var d: CGFloat = 0, run = 0
        var first: Hit?
        while d <= limit {
            let q = CGPoint(x: start.x + dx * d, y: start.y + dy * d)
            let l = mask.label(at: toImage(q))
            if l != .faceSkin {
                if run == 0 { first = Hit(point: q, label: l) }
                run += 1
                if run >= 3, let f = first {
                    // Report the boundary halfway between the last skin sample and the first non-skin one,
                    // and what the walk ran into there.
                    return Hit(point: CGPoint(x: f.point.x - dx * step / 2, y: f.point.y - dy * step / 2), label: f.label)
                }
            } else { run = 0 }
            d += step
        }
        return nil
    }
}
