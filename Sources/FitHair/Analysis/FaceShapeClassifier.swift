import Foundation

struct ShapeScore: Identifiable, Equatable {
    let shape: FaceShape
    let probability: Double
    var id: FaceShape { shape }
    var percent: Int { Int((probability * 100).rounded()) }
}

struct Classification: Equatable {
    /// Normalised similarities to the reference proportions, not calibrated probabilities.
    let scores: [ShapeScore]
    var candidates: [FaceShape]
    var isUncertain: Bool
    var needsRetake: Bool
    var primary: FaceShape { scores[0].shape }
    /// The runner-up, shown as "偏 X 形" when it is strong enough.
    var secondary: ShapeScore? { scores.count > 1 && scores[1].probability >= 0.15 ? scores[1] : nil }
    func probability(of shape: FaceShape) -> Double { scores.first { $0.shape == shape }?.probability ?? 0 }

    /// When the measurement sits near a boundary, recommend for the plausible shapes together.
    var recommendationScores: [ShapeScore] {
        guard isUncertain else { return [.init(shape: primary, probability: 1)] }
        let selected = scores.filter { candidates.contains($0.shape) }
        let total = selected.map(\.probability).reduce(0, +)
        return selected.map { .init(shape: $0.shape, probability: $0.probability / total) }
    }

    var candidateNames: String { candidates.map(\.name).joined(separator: "、") }
}

/// Compares measured ratios with each shape's typical proportions (a soft nearest-prototype rule).
/// The prototypes and spreads are a first draft from stylist guidelines and should be calibrated
/// with hand-labelled selfies before launch.
enum FaceShapeClassifier {
    /// How far (in each unit) a ratio can drift before it counts as "one step" away.
    /// Set to about twice the frame-to-frame measurement noise (RepeatabilityTests), on the compressed scale
    /// this measuring method produces — see the note on `FaceShape.prototype`.
    static let spread = FaceRatios(lengthToWidth: 0.07, foreheadToCheek: 0.036, jawToCheek: 0.042, jawAngle: 7)

    /// The runner-up has to reach this share of the winner's score for the verdict to count as undecided.
    /// The lowest bar that still passes RepeatabilityTests (a noisy photo must never give a confident wrong
    /// answer). Set on the reference busts only; needs checking against labelled real photographs.
    static let closeRatio = 0.45
    /// Candidates named when undecided: anything this close to the winner, three at most.
    static let candidateRatio = 0.3

    static func classify(_ r: FaceRatios) -> Classification {
        guard [r.lengthToWidth, r.foreheadToCheek, r.jawToCheek, r.jawAngle].allSatisfy({ $0.isFinite && $0 > 0 }),
              r.lengthToWidth < 10, r.foreheadToCheek < 10, r.jawToCheek < 10, r.jawAngle <= 180 else {
            return Classification(scores: FaceShape.allCases.map { .init(shape: $0, probability: 1.0 / 7) },
                                  candidates: FaceShape.allCases, isUncertain: true, needsRetake: true)
        }
        let logits: [(FaceShape, Double)] = FaceShape.allCases.map { shape in
            (shape, -distance(r, shape.prototype) / 2)
        }
        let m = logits.map(\.1).max() ?? 0
        let exps = logits.map { ($0.0, exp($0.1 - m)) }
        let total = exps.map(\.1).reduce(0, +)
        let scores = exps.map { ShapeScore(shape: $0.0, probability: $0.1 / total) }
            .sorted { $0.probability > $1.probability }
        let needsRetake = -2 * m > 9
        // Undecided only when the runner-up is genuinely close.
        let uncertain = needsRetake || scores[1].probability >= scores[0].probability * closeRatio
        return Classification(scores: scores, candidates: uncertain ? closest(scores) : [scores[0].shape],
                              isUncertain: uncertain, needsRetake: needsRetake)
    }

    private static func closest(_ scores: [ShapeScore]) -> [FaceShape] {
        let near = scores.dropFirst(2).filter { $0.probability >= scores[0].probability * candidateRatio }
        return Array((Array(scores.prefix(2)) + near).prefix(3).map(\.shape))
    }

    static func classify(_ measurement: FaceMeasurement) -> Classification {
        var result = classify(measurement.ratios)
        let poseOff = abs(measurement.yaw ?? 0) > 12 || abs(measurement.pitch ?? 0) > 12
        let moving = measurement.spread.map {
            $0.lengthToWidth > 0.08 || $0.foreheadToCheek > 0.08 || $0.jawToCheek > 0.08 || $0.jawAngle > 8
        } ?? false
        if poseOff || moving || measurement.otherFaces > 0 || measurement.faceTooSmall || measurement.faceCutOff || measurement.tiltedTooFar {
            result.needsRetake = true
        }
        if result.needsRetake || !measurement.hairlineMeasured || !measurement.foreheadMeasured {
            result.isUncertain = true
            if result.candidates.count < 2 { result.candidates = result.scores.prefix(2).map(\.shape) }
        }
        return result
    }

    private static func distance(_ r: FaceRatios, _ p: FaceRatios) -> Double {
        sq((r.lengthToWidth - p.lengthToWidth) / spread.lengthToWidth)
            + sq((r.foreheadToCheek - p.foreheadToCheek) / spread.foreheadToCheek)
            + sq((r.jawToCheek - p.jawToCheek) / spread.jawToCheek)
            + sq((r.jawAngle - p.jawAngle) / spread.jawAngle)
    }

    private static func sq(_ x: Double) -> Double { x * x }
}
