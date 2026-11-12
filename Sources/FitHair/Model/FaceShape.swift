import Foundation

/// The seven face-shape pools.
enum FaceShape: String, CaseIterable, Identifiable, Codable {
    case oval, round, square, heart, oblong, diamond, triangle

    var id: String { rawValue }

    var name: String {
        switch self {
        case .oval: "鹅蛋脸"
        case .round: "圆脸"
        case .square: "方脸"
        case .heart: "心形脸"
        case .oblong: "长脸"
        case .diamond: "菱形脸"
        case .triangle: "三角脸"
        }
    }

    var short: String {
        switch self {
        case .oval: "鹅蛋"
        case .round: "圆"
        case .square: "方"
        case .heart: "心形"
        case .oblong: "长"
        case .diamond: "菱形"
        case .triangle: "三角"
        }
    }

    var english: String { rawValue.uppercased() }

    /// "偏心形" / "偏圆形" — the short name with 形, without doubling it.
    var leaning: String { "偏" + (short.hasSuffix("形") ? short : short + "形") }

    var number: String { String(format: "%02d", (FaceShape.allCases.firstIndex(of: self) ?? 0) + 1) }

    /// One line about hair, shown on the home page.
    var hairLine: String {
        switch self {
        case .oval: "什么发型，都撑得住。"
        case .round: "把高度给头顶，脸就长了。"
        case .square: "用一点弧度，柔化棱角。"
        case .heart: "刘海侧分，重量放到下巴。"
        case .oblong: "一道刘海，脸就短了。"
        case .diamond: "遮住额角，补满下颌。"
        case .triangle: "把量感留给头顶。"
        }
    }

    /// What the cut should do for this face, in the words you'd use with a hairdresser.
    func barberGoal(for gender: Gender) -> String {
        switch self {
        case .oval: "脸型比例比较均衡，主要保持好发型的轮廓。"
        case .round: "想让脸看起来长一点：头顶有高度，两侧不要太蓬。"
        case .square: gender == .male ? "想让轮廓利落一点：两侧收干净，留住下颌线条。" : "想柔和一下下颌的棱角：发尾和两侧留点弧度。"
        case .heart: "想平衡偏窄的下巴：额头收一点，量感放到下巴附近。"
        case .oblong: "想让脸看起来短一点：用刘海和两侧的量感，头顶不要太高。"
        case .diamond: "想柔和一下颧骨：遮一点额角，下巴附近留点量。"
        case .triangle: "想平衡偏宽的下颌：量感放到头顶和两侧上方。"
        }
    }

    var note: String {
        switch self {
        case .oval: "额头略宽于下颌，下颌线圆润。"
        case .round: "颧骨最宽，下颌没有棱角。"
        case .square: "三处一样宽，下颌角分明。"
        case .heart: "额头最宽，往下收到尖下巴。"
        case .oblong: "三处宽度接近，整张脸偏长。"
        case .diamond: "颧骨突出，额头和下巴偏窄。"
        case .triangle: "下颌最宽，额头最窄。"
        }
    }

    var suits: String {
        switch self {
        case .oval: "比例均衡，大部分发型都能驾驭。先试有层次的锁骨发、齐肩波波。"
        case .round: "头顶蓬松、侧分，过锁骨的长层次，拉长视觉比例。"
        case .square: "柔软层次和波浪，长度过下颌；男生可用渐变短发强化棱角。"
        case .heart: "侧分长刘海收窄额头，下巴位置有量感的波波或卷发。"
        case .oblong: "刘海缩短脸长，两侧加量、齐肩卷发。"
        case .diamond: "刘海遮住窄额头，下颌附近加量，一侧别到耳后。"
        case .triangle: "头顶和额头两侧加量，刘海和上半部分做层次。"
        }
    }

    var avoid: String {
        switch self {
        case .oval: "又长又厚、没有层次的直发，会把脸拉长。"
        case .round: "厚重齐刘海、齐下巴的圆波波、两侧蓬松。"
        case .square: "正好齐下颌的一刀切、厚重齐刘海。"
        case .heart: "头顶堆得过高，两侧剪得太短太贴。"
        case .oblong: "头顶高耸、超长直发、无刘海中分。"
        case .diamond: "颧骨位置蓬松，中分紧贴头皮。"
        case .triangle: "下颌长度的蓬松波波，头顶压得很平。"
        }
    }

    /// Typical proportions of this shape. These are also the classifier prototypes.
    /// Jaw angle is the frontal cheekbone → jaw corner → chin angle measured by FaceAnalyzer.
    ///
    /// Calibration (2026-11): 30 % stylist textbook proportions (mapped onto the scale this measuring method
    /// actually produces — jaw at the gonion and cheek at the widest contour point compress the textbook ratios
    /// by about 5×) and 70 % what FaceAnalyzer measures on the seven reference busts in Resources/, decoded the
    /// way the app decodes photos. With this table every bust classifies as itself
    /// (ClassifierTests.testBustsClassifyAsThemselves). The oval/diamond and square/triangle busts look nearly
    /// the same to the camera, so those pairs sit close together. Still to do: calibrate on labelled photos of real people.
    var prototype: FaceRatios {
        switch self {
        case .oval: FaceRatios(lengthToWidth: 1.35, foreheadToCheek: 0.77, jawToCheek: 0.75, jawAngle: 136)
        case .round: FaceRatios(lengthToWidth: 1.17, foreheadToCheek: 0.81, jawToCheek: 0.79, jawAngle: 129)
        case .square: FaceRatios(lengthToWidth: 1.26, foreheadToCheek: 0.79, jawToCheek: 0.78, jawAngle: 132)
        case .heart: FaceRatios(lengthToWidth: 1.29, foreheadToCheek: 0.83, jawToCheek: 0.73, jawAngle: 139)
        case .oblong: FaceRatios(lengthToWidth: 1.46, foreheadToCheek: 0.83, jawToCheek: 0.80, jawAngle: 132)
        case .diamond: FaceRatios(lengthToWidth: 1.34, foreheadToCheek: 0.79, jawToCheek: 0.77, jawAngle: 135)
        case .triangle: FaceRatios(lengthToWidth: 1.26, foreheadToCheek: 0.76, jawToCheek: 0.80, jawAngle: 130)
        }
    }

    /// Forehead / cheekbone / jaw widths normalised to the widest one (for the proportion diagram).
    var widths: [Double] {
        let p = prototype
        let raw = [p.foreheadToCheek, 1.0, p.jawToCheek]
        let m = raw.max() ?? 1
        return raw.map { $0 / m }
    }

    var imageName: String { "shape-\(rawValue)" }
}

/// The four numbers the classifier works on.
struct FaceRatios: Equatable, Codable {
    /// Face length ÷ widest of forehead / cheekbone / jaw.
    var lengthToWidth: Double
    var foreheadToCheek: Double
    var jawToCheek: Double
    /// Average jaw angle at the jaw corners, in degrees (larger = softer).
    var jawAngle: Double
}
