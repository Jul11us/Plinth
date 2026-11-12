import SwiftUI

/// The user's photo with the measurement drawn on top like an anatomy sketch:
/// a fine traced face outline, three hairline widths with dot ends, a jaw-angle arc,
/// and quiet labels set outside the face. The drawing animates on when it appears.
struct MeasuredPhoto: View {
    let image: CGImage
    var measurement: FaceMeasurement?
    /// Upper limit on how many measurement layers to show (0…4) — lets a caller hold some back.
    var reveal: Int = 4
    var showAllPoints = false
    /// Draw the measurement sketch (false = just the photo, cropped to the face).
    var showSketch = true
    var zoomToFace = true
    /// Draw everything at once with no animation (for rendering to an image).
    var still = false

    @State private var drawn: CGFloat = 0
    @State private var shown = 0

    private let ink = Color(hex: 0x1A1A1A)

    var body: some View {
        GeometryReader { geo in
            let crop = cropRect
            let scale = max(geo.size.width / crop.width, geo.size.height / crop.height)
            let ox = (geo.size.width - crop.width * scale) / 2 - crop.minX * scale
            let oy = (geo.size.height - crop.height * scale) / 2 - crop.minY * scale
            let map = { (p: CGPoint) in CGPoint(x: ox + p.x * scale, y: oy + p.y * scale) }
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    .offset(x: ox, y: oy)
                if showSketch, let m = measurement {
                    sketch(m, map: map, size: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .onAppear { if measurement != nil && showSketch { play() } }
        .onChange(of: measurement != nil) { _, has in if has && showSketch { play() } }
    }

    private func play() {
        drawn = 0; shown = 0
        withAnimation(.easeInOut(duration: 1.1)) { drawn = 1 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            for i in 1...4 {
                withAnimation(.easeOut(duration: 0.35)) { shown = i }
                try? await Task.sleep(for: .milliseconds(220))
            }
        }
    }

    private func visible(_ layer: Int) -> Double { ((still ? 4 : shown) >= layer && reveal >= layer) ? 1 : 0 }

    // MARK: The sketch

    @ViewBuilder
    private func sketch(_ m: FaceMeasurement, map: @escaping (CGPoint) -> CGPoint, size: CGSize) -> some View {
        let g = SketchGeometry(m, map: map, size: size)
        ZStack(alignment: .topLeading) {
            if showAllPoints {
                ForEach(Array(m.allPoints.enumerated()), id: \.offset) { _, p in
                    Circle().fill(.white.opacity(0.85)).frame(width: 3, height: 3).position(map(p))
                }
                .opacity(1 - Double(drawn) * 0.6)
            }

            // Only what was measured: one smooth U from cheekbone to cheekbone through the jaw and chin.
            // The top of the head is never measured, so it isn't drawn.
            if g.outline.count > 2 {
                Polyline(points: g.outline)
                    .trim(from: 0, to: still ? 1 : drawn)
                    .stroke(ink.opacity(0.72), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }

            // Vertical axis, hairline to chin
            Group {
                Polyline(points: [g.axisTop, g.axisBottom])
                    .stroke(ink.opacity(0.28), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                Polyline(points: [g.axisTop.moved(-4, 0), g.axisTop.moved(4, 0)]).stroke(ink.opacity(0.55), lineWidth: 0.8)
                Polyline(points: [g.axisBottom.moved(-4, 0), g.axisBottom.moved(4, 0)]).stroke(ink.opacity(0.55), lineWidth: 0.8)
            }
            .opacity(visible(4))

            // Temples: a faint dashed line from each forehead end down to the cheekbone end, so the
            // forehead width doesn't float above the outline and the measured region reads as one shape.
            ForEach(Array(g.temples.enumerated()), id: \.offset) { _, t in
                Polyline(points: t)
                    .stroke(ink.opacity(0.3), style: StrokeStyle(lineWidth: 0.6, lineCap: .round, dash: [2, 3]))
            }
            .opacity(visible(1))

            // Level width lines, ends sitting on the outline
            ForEach(Array(g.widths.enumerated()), id: \.offset) { i, w in
                Group {
                    Polyline(points: [w.a, w.b])
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: w.estimated ? [3, 3] : []))
                    EndDot(hollow: w.estimated).position(w.a)
                    EndDot(hollow: w.estimated).position(w.b)
                }
                .opacity(visible(i + 1))
            }

            // Jaw angle, on the same side as the labels
            AngleArc(vertex: g.angleVertex, toward: g.angleToward, and: g.angleAnd, radius: 13)
                .stroke(Theme.accent, lineWidth: 1)
                .opacity(visible(3))

            // One right-hand column of labels, each with a quiet leader
            ForEach(Array(g.rows.enumerated()), id: \.offset) { _, r in
                Group {
                    Polyline(points: g.leader(for: r))
                        .stroke(ink.opacity(0.3), style: StrokeStyle(lineWidth: 0.6, lineCap: .round, dash: [0.1, 2.5]))
                    caption(r, at: CGPoint(x: g.labelX, y: r.y), in: size)
                }
                .opacity(visible(r.layer))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// A label pinned at `p`. It lives in an overlay of a fixed-size clear box, so its own size can never
    /// grow the drawing's container (which would shift every line).
    private func caption(_ r: LabelRow, at p: CGPoint, in size: CGSize) -> some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Text(r.name).font(.system(size: 11)).foregroundStyle(Color.fhSecondary)
                        .frame(width: 26, alignment: .leading)
                    Text(r.value).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(ink)
                    if let note = r.note {
                        Text(note).font(.system(size: 10)).monospacedDigit().foregroundStyle(Color.fhSecondary)
                    }
                }
                .shadow(color: .white.opacity(0.95), radius: 1.5)
                .shadow(color: .white.opacity(0.8), radius: 3)
                .fixedSize()
                .alignmentGuide(.top) { $0.height / 2 }
                .offset(x: p.x, y: p.y)
            }
    }

    /// Crop around the face, leaving room on the right for the labels.
    private var cropRect: CGRect {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard zoomToFace, let m = measurement else { return full }
        let k = m.keyPoints
        let xs = [k.cheekLeft.x, k.cheekRight.x, k.foreheadLeft.x, k.foreheadRight.x, k.jawLeft.x, k.jawRight.x] + m.contour.map(\.x)
        let faceW = (xs.max()! - xs.min()!)
        // With the sketch, shift right to leave room for the label column; without it, a looser portrait
        // crop centred on the face (hair to the base of the neck), as on the try-on page.
        let cx = (xs.max()! + xs.min()!) / 2 + (showSketch ? faceW * 0.14 : 0)
        let top = k.hairline.y - faceW * (showSketch ? 0.45 : 0.8)
        let bottom = k.chin.y + faceW * (showSketch ? 0.35 : 0.5)
        var h = bottom - top
        var w = h * 0.8
        if w < faceW * 1.9 { w = faceW * 1.9; h = w / 0.8 }
        let r = CGRect(x: cx - w / 2, y: (top + bottom) / 2 - h / 2, width: w, height: h)
        return r.intersection(full).isEmpty ? full : r
    }
}


// MARK: Geometry

struct LabelRow {
    let name: String, value: String, note: String?
    let anchor: CGPoint
    var y: CGFloat
    let layer: Int
}

/// All the drawing positions, worked out once in view space so every line is level and lands on the outline.
private struct SketchGeometry {
    var outline: [CGPoint] = []
    var axisTop = CGPoint.zero, axisBottom = CGPoint.zero
    var widths: [(a: CGPoint, b: CGPoint, estimated: Bool)] = []
    var temples: [[CGPoint]] = []
    var angleVertex = CGPoint.zero, angleToward = CGPoint.zero, angleAnd = CGPoint.zero
    var rows: [LabelRow] = []
    var labelX: CGFloat = 0

    init(_ m: FaceMeasurement, map: (CGPoint) -> CGPoint, size: CGSize) {
        let k = m.keyPoints
        let raw = m.contour.map(map)
        let hair = map(k.hairline), chin = map(k.chin)

        // Forehead line, levelled
        let fa = map(k.foreheadLeft), fb = map(k.foreheadRight)
        let fy = (fa.y + fb.y) / 2
        let fl = CGPoint(x: min(fa.x, fb.x), y: fy), fr = CGPoint(x: max(fa.x, fb.x), y: fy)

        // Outline: the measured contour between the two cheekbone points, lightly smoothed so small
        // wobbles from the landmark model don't show, then drawn as a smooth curve.
        let axisX = chin.x   // the chin sits on the face's midline even when the head turns a little
        if raw.count > 2 {
            func nearest(_ p: CGPoint) -> Int {
                raw.indices.min { hypot(raw[$0].x - p.x, raw[$0].y - p.y) < hypot(raw[$1].x - p.x, raw[$1].y - p.y) }!
            }
            let i = nearest(map(k.cheekLeft)), j = nearest(map(k.cheekRight))
            var u = Array(raw[min(i, j)...max(i, j)])
            if u.count > 3 {   // one light pass, sideways only: every point keeps its height, so the chin stays put
                u = u.indices.map { n in
                    n == 0 || n == u.count - 1 ? u[n]
                        : CGPoint(x: (u[n - 1].x + 2 * u[n].x + u[n + 1].x) / 4, y: u[n].y)
                }
            }
            outline = FaceAnalyzer.catmullRom(u, samplesPerSegment: 12)
        }

        axisTop = CGPoint(x: axisX, y: hair.y)
        axisBottom = CGPoint(x: axisX, y: chin.y)

        func level(_ a: CGPoint, _ b: CGPoint, snap: Bool) -> (CGPoint, CGPoint) {
            let y = (a.y + b.y) / 2
            guard snap else { return (CGPoint(x: a.x, y: y), CGPoint(x: b.x, y: y)) }
            return (CGPoint(x: Self.x(on: outline, atY: y, near: a.x), y: y),
                    CGPoint(x: Self.x(on: outline, atY: y, near: b.x), y: y))
        }
        let fh = (fl, fr)
        let ck = level(map(k.cheekLeft), map(k.cheekRight), snap: true)
        let jw = level(map(k.jawLeft), map(k.jawRight), snap: true)
        widths = [(fh.0, fh.1, !m.foreheadMeasured), (ck.0, ck.1, false), (jw.0, jw.1, false)]
        let ckL = ck.0.x <= ck.1.x ? ck.0 : ck.1, ckR = ck.0.x <= ck.1.x ? ck.1 : ck.0
        temples = [[fl, ckL], [fr, ckR]]

        // Angle on the right jaw corner (the label side)
        let rightJaw = jw.0.x > jw.1.x ? jw.0 : jw.1
        let rightCheek = ck.0.x > ck.1.x ? ck.0 : ck.1
        angleVertex = rightJaw; angleToward = rightCheek; angleAnd = chin

        let faceRight = ([fh.0.x, fh.1.x, ck.0.x, ck.1.x] + outline.map(\.x)).max() ?? size.width / 2
        labelX = min(faceRight + 22, size.width - 120)

        let r = m.ratios
        func right(_ p: (CGPoint, CGPoint)) -> CGPoint { p.0.x > p.1.x ? p.0 : p.1 }
        var list = [
            LabelRow(name: "额头", value: String(format: "%.2f", r.foreheadToCheek), note: m.foreheadMeasured ? nil : "估算", anchor: right(fh), y: fh.0.y, layer: 1),
            LabelRow(name: "颧骨", value: "1.00", note: nil, anchor: right(ck), y: ck.0.y, layer: 2),
            LabelRow(name: "下颌", value: String(format: "%.2f", r.jawToCheek), note: String(format: "角 %.0f°", r.jawAngle), anchor: right(jw), y: jw.0.y, layer: 3),
            LabelRow(name: "长宽", value: String(format: "%.2f", r.lengthToWidth), note: m.hairlineMeasured ? nil : "估算", anchor: axisBottom, y: axisBottom.y, layer: 4),
        ]
        // Keep rows at least 22 pt apart
        list.sort { $0.y < $1.y }
        for i in 1..<list.count where list[i].y < list[i - 1].y + 22 { list[i].y = list[i - 1].y + 22 }
        rows = list
    }

    /// Leader from a measured point to its label: level, with a short bend only if the label had to move.
    func leader(for r: LabelRow) -> [CGPoint] {
        let start = CGPoint(x: r.anchor.x + 7, y: r.anchor.y)
        let end = CGPoint(x: labelX - 6, y: r.y)
        if abs(r.y - r.anchor.y) < 0.5 { return [start, end] }
        return [start, CGPoint(x: labelX - 16, y: r.anchor.y), end]
    }

    /// Where the outline crosses height `y`, on the side nearest `x0` (falls back to `x0`).
    static func x(on curve: [CGPoint], atY y: CGFloat, near x0: CGFloat) -> CGFloat {
        var best: CGFloat?
        for (a, b) in zip(curve, curve.dropFirst()) where (a.y - y) * (b.y - y) <= 0 && a.y != b.y {
            let x = a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y)
            if best == nil || abs(x - x0) < abs(best! - x0) { best = x }
        }
        if let b = best, abs(b - x0) < 30 { return b }
        return x0
    }
}

private extension CGPoint {
    func moved(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}

// MARK: Shapes

private struct Polyline: Shape {
    let points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        points.dropFirst().forEach { p.addLine(to: $0) }
        return p
    }
}

/// The inner angle at `vertex`, drawn by sampling so it always sits on the inside of the corner.
private struct AngleArc: Shape {
    let vertex: CGPoint, toward: CGPoint, and: CGPoint, radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let a1 = atan2(toward.y - vertex.y, toward.x - vertex.x)
        let a2 = atan2(and.y - vertex.y, and.x - vertex.x)
        var d = a2 - a1
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        var p = Path()
        for i in 0...24 {
            let a = a1 + d * CGFloat(i) / 24
            let q = CGPoint(x: vertex.x + radius * cos(a), y: vertex.y + radius * sin(a))
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        return p
    }
}

/// Solid = measured, hollow = estimated.
private struct EndDot: View {
    var hollow = false
    var body: some View {
        Circle().fill(hollow ? Color.white : Theme.accent)
            .frame(width: 5, height: 5)
            .overlay(Circle().stroke(hollow ? Theme.accent : .white, lineWidth: 1))
    }
}
