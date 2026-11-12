import CoreML
import CoreGraphics
import Foundation

/// Hair / face-skin segmentation with Google's MediaPipe multiclass selfie model (Apache-2.0),
/// converted to Core ML by `scripts/convert-hair-model.py`. Runs on-device in a few milliseconds.
enum HairSegmenter {
    enum Label: UInt8 { case background = 0, hair, bodySkin, faceSkin, clothes, other }

    static let side = 256

    /// A 256×256 label map covering `crop` (image pixels, origin top-left).
    struct Mask {
        let crop: CGRect
        let labels: [UInt8]

        /// Label under an image-pixel point; points outside the crop count as background.
        func label(at p: CGPoint) -> Label {
            let x = Int(((p.x - crop.minX) / crop.width * CGFloat(side)).rounded(.down))
            let y = Int(((p.y - crop.minY) / crop.height * CGFloat(side)).rounded(.down))
            guard x >= 0, y >= 0, x < side, y < side else { return .background }
            return Label(rawValue: labels[y * side + x]) ?? .other
        }
    }

    private static let model: MLModel? = {
        guard let url = Res.url("HairSegmenter", "mlmodelc") else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: config)
    }()

    static var isAvailable: Bool { model != nil }

    /// Segments the square `crop` of `image`. Parts of the crop outside the photo are filled with grey.
    static func segment(_ image: CGImage, crop: CGRect) -> Mask? {
        guard let model, crop.width > 8, crop.height > 8 else { return nil }
        let n = side * side
        var px = [UInt8](repeating: 128, count: n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            // Context origin is bottom-left; bitmap row 0 is the top of the crop.
            let s = CGFloat(side) / crop.width
            let h = CGFloat(image.height)
            ctx.draw(image, in: CGRect(x: -crop.minX * s, y: -(h - crop.maxY) * s,
                                       width: CGFloat(image.width) * s, height: h * s))
            return true
        }
        guard drawn, let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        else { return nil }
        let ip = input.dataPointer.bindMemory(to: Float.self, capacity: 3 * n)
        for i in 0..<n {
            for c in 0..<3 { ip[c * n + i] = (Float(px[i * 4 + c]) - 127.5) / 127.5 }
        }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])),
              let seg = out.featureValue(for: "segmentation")?.multiArrayValue else { return nil }

        let st = seg.strides.map(\.intValue)
        var labels = [UInt8](repeating: 0, count: n)
        if seg.dataType == .float32 {
            let p = seg.dataPointer.bindMemory(to: Float.self, capacity: seg.count)
            for y in 0..<side {
                for x in 0..<side {
                    let base = y * st[2] + x * st[3]
                    var best = 0, bv = -Float.infinity
                    for c in 0..<6 { let v = p[c * st[1] + base]; if v > bv { bv = v; best = c } }
                    labels[y * side + x] = UInt8(best)
                }
            }
        } else {
            for y in 0..<side {
                for x in 0..<side {
                    let base = y * st[2] + x * st[3]
                    var best = 0, bv = -Float.infinity
                    for c in 0..<6 { let v = seg[c * st[1] + base].floatValue; if v > bv { bv = v; best = c } }
                    labels[y * side + x] = UInt8(best)
                }
            }
        }
        return Mask(crop: crop, labels: labels)
    }
}
