import CoreML
import CoreGraphics
import Foundation
import simd

/// Redraws the pasted hair of a try-on as real hair with an image model that runs on this Mac: Stable Diffusion
/// inpainting, converted to Core ML. The pasted preview is only a sketch of the cut: the model grows the hair
/// again on this head, together with the skin it meets (`HairTryOn.Repaint.blend`), so it has a hairline,
/// sideburns and faded sides of its own. Outside `mask` and `blend` everything stays the photo's own pixels.
/// The settings were found by trying it on real photos with `scripts/repaint-proto.py`, which says why each is what it is.
actor HairRepaint {
    static let shared = HairRepaint()

    enum Failure: LocalizedError {
        case notInstalled, model(String), image
        var errorDescription: String? {
            switch self {
            case .notInstalled: "写实效果的模型还没有安装。"
            case .model(let what): "写实效果的模型运行出错：\(what)"
            case .image: "这张试戴图读不出来。"
            }
        }
    }

    /// Where the model is: inside the app when the app was packaged with it (`build-dmg.sh --with-model`),
    /// otherwise in Application Support, which is also where a download puts it. `PLINTH_MODEL_DIR` points it
    /// somewhere else, for trying out a download without touching the model that is installed.
    nonisolated static var folder: URL {
        folder(override: ProcessInfo.processInfo.environment["PLINTH_MODEL_DIR"],
               packaged: Bundle.main.resourceURL?.appendingPathComponent("RepaintModel"),
               support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    nonisolated static func folder(override: String?, packaged: URL?, support: URL) -> URL {
        if let override, !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
        // Only a whole model: half of one in the app must not hide a good one outside it.
        if let packaged, files.allSatisfy({ FileManager.default.fileExists(atPath: packaged.appendingPathComponent($0).path) }) {
            return packaged
        }
        return support.appendingPathComponent("Plinth/RepaintModel")
    }

    /// What has to be in the folder for the model to count as installed.
    nonisolated static let files = ["TextEncoder.mlmodelc", "Unet.mlmodelc", "VAEEncoder.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"]

    nonisolated static var isInstalled: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    // MARK: Settings

    /// The model works on a 512-pixel square, which it sees as a 64 × 64 grid.
    private static let side = 512, grid = 64
    private static let steps = 12
    /// How far the hair may leave the draft: 7 of the 12 steps. With 6 the result is the bust's carved hair with a
    /// hair texture, sitting on the head like a wig; with 7 the model draws strands, curls and a fade of its own
    /// inside the same outline. With 8 and more the cut drifts (a curtain fringe turns into a straight one) and
    /// the colour goes to whatever the prompt's colour word means to the model.
    private static let strength: Float = 0.6
    /// Guidance doubles the work of a step and matters most early on, so the hair only gets it for its first steps.
    private static let guidedPart: Float = 0.6
    /// Room around the pasted hair for loose strands and an outline that is not the bust's.
    private static let looseRoom = 14
    /// The most fine contrast added to hair that came out softer than the photo; beyond it edges grow halos.
    private static let sharpenAtMost: Float = 1.5
    private static let guidance: Float = 6.5
    /// When the new style leaves any real part of the canvas bare, what was behind the old hair is redrawn first, in
    /// a pass of its own. Leaving it to the hair pass looks fine from a distance and smeared up close.
    private static let clearOver: Float = 0.004
    /// Next to a head the model sometimes grows the old hair back. This much hair where there should be none, as a
    /// share of the canvas, is cleared again from a different start, at most `clearAgain` times.
    private static let leftoverOver: Float = 0.002
    private static let clearAgain = 2
    /// The clear pass starts from the smoothed-over photo rather than from nothing, so clothes keep their colours.
    private static let clearStrength: Float = 0.88
    // Stronger guidance (9, 12) was tried for the clear pass: it clears long hair no better and invents stains and
    // objects. Whether long hair is fully cleared varies with the noise it starts from.
    private static let latentScale: Float = 0.18215

    private static let hairNegative = "glossy, shiny, wet hair, hair gel, wig, plastic, sculpture, clay, painting, cartoon, 3d render, hat, headband, hair clip, hairpin, beads, earrings, "
        + "blurry, smudged, extra face, extra ear, deformed, text"
    private static let clearPrompt = "photo, plain background, bare neck, ears, shoulders, clothes"
    private static let clearNegative = "hair, long hair, ponytail, braid, strands, wig, fur, hat, head, face, extra person, hand, earrings, text, blurry"

    // MARK: Model

    private struct Models {
        let tokenizer: ClipTokenizer
        let text, unet, encoder, decoder: MLModel
    }

    private var models: Models?
    private var embeddings: [String: [Float]] = [:]

    /// Gives the memory back, about 2 GB. The next picture loads the model again.
    func unload() {
        idle?.cancel()
        idle = nil
        models = nil
        embeddings = [:]
        cleared = [:]
        clearedOrder = []
    }

    /// Loads the model before the first picture is asked for, so that picture doesn't wait for it. Whoever can
    /// tell that a try-on is likely calls this: the page the try-on is opened from, and the try-on itself.
    func prepare() {
        guard Self.isInstalled else { return }
        _ = try? loaded()
        stayAwhile()
    }

    /// The model is kept this long after it was last used, then its memory is given back: long enough to go and
    /// pick another style and come back without loading it again.
    private static let keptFor: Duration = .seconds(180)
    private var idle: Task<Void, Never>?

    private func stayAwhile() {
        idle?.cancel()
        idle = Task {
            try? await Task.sleep(for: Self.keptFor)
            guard !Task.isCancelled else { return }
            unload()
        }
    }

    /// What was behind the old hair, by scene: redrawing it is the longer half of a picture, and it is the same
    /// for every colour of one style on one photo.
    private var cleared: [String: (area: [Float], picture: [SIMD3<Float>])] = [:]
    private var clearedOrder: [String] = []
    private static let clearedKept = 3

    private func loaded() throws -> Models {
        if let models { return models }
        guard Self.isInstalled else { throw Failure.notInstalled }
        let folder = Self.folder
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        func model(_ name: String) throws -> MLModel {
            try MLModel(contentsOf: folder.appendingPathComponent(name + ".mlmodelc"), configuration: configuration)
        }
        do {
            let ready = Models(tokenizer: try ClipTokenizer(vocabulary: folder.appendingPathComponent("vocab.json"),
                                                            merges: folder.appendingPathComponent("merges.txt")),
                               text: try model("TextEncoder"), unet: try model("Unet"),
                               encoder: try model("VAEEncoder"), decoder: try model("VAEDecoder"))
            models = ready
            return ready
        } catch {
            throw Failure.model(error.localizedDescription)
        }
    }

    // MARK: Repaint

    /// What `render` is busy with, for whoever shows it to the user.
    enum Step: Sendable { case loading, clearing, drawing, finishing }

    /// The try-on with its hair redrawn. `style` is the cut in English, `colour` the dye in English or nil for the
    /// colour the draft already has. `scene` names the photo and the style, whatever the colour: pictures of one
    /// scene share what was redrawn behind the old hair. Stops between steps when the task is cancelled.
    func render(_ draft: HairTryOn.Output, style: String, colour: String?, scene: String? = nil,
                report: (@Sendable (Step) -> Void)? = nil) throws -> CGImage {
        stayAwhile()
        defer { stayAwhile() }
        let w = HairTryOn.width, h = HairTryOn.height
        guard let extra = draft.repaint, let pasted = Self.pixels(draft.image, w, h), let photo = Self.pixels(draft.original, w, h),
              let maskPixels = Self.pixels(extra.mask, w, h), let hairPixels = Self.pixels(extra.hair, w, h),
              let blendPixels = Self.pixels(extra.blend, w, h) else { throw Failure.image }
        let mask = maskPixels.map { $0.x > 0.5 ? Float(1) : 0 }
        let hair = hairPixels.map(\.x)
        guard mask.contains(1) else { return draft.image }

        // Where the new hair is, with room for loose strands, and the skin it meets.
        let near = HairTryOn.box(hair.map { $0 > 0.05 ? Float(1) : 0 }, width: w, height: h, radius: Self.looseRoom)
        let hairArea = mask.indices.map { (mask[$0] > 0 && near[$0] > 0.001) || blendPixels[$0].x > 0.5 ? Float(1) : 0 }
        let bare = zip(mask, hairArea).reduce(0) { $0 + ($1.0 > 0 && $1.1 == 0 ? 1 : 0) }
        let twoPasses = Float(bare) / Float(w * h) > Self.clearOver

        if models == nil {
            report?(.loading)
            _ = try loaded()
        }
        var result = photo
        let clear = mask.indices.map { mask[$0] > 0 && hair[$0] <= 0.5 ? Float(1) : 0 }
        if twoPasses, let scene, let kept = cleared[scene], kept.area == clear {
            result = kept.picture
        } else if twoPasses {
            report?(.clearing)
            result = try redraw(photo, from: pasted, mask: clear, prompt: Self.clearPrompt, negative: Self.clearNegative,
                                strength: Self.clearStrength, guidedPart: 1, seed: 7).image
            for attempt in 1...Self.clearAgain {
                // Judged with the new hair in place, the way the model saw it.
                let shown = result.indices.map { hair[$0] > 0.5 ? pasted[$0] : result[$0] }
                guard let left = Self.leftoverHair(in: shown, clear: clear, hairArea: hairArea, w: w, h: h) else { break }
                // Start from a smooth fill, so there is no hair in it to keep.
                let filled = HairTryOn.pullPush(shown, weights: left.map { 1 - $0 }, width: w, height: h)
                result = try redraw(result, from: filled, mask: left, prompt: Self.clearPrompt, negative: Self.clearNegative,
                                    strength: Self.clearStrength, guidedPart: 1, seed: 7 + UInt64(attempt)).image
            }
            if let scene {
                cleared[scene] = (clear, result)
                clearedOrder.removeAll { $0 == scene }
                clearedOrder.append(scene)
                while clearedOrder.count > Self.clearedKept { cleared.removeValue(forKey: clearedOrder.removeFirst()) }
            }
        }
        report?(.drawing)
        let target = twoPasses ? hairArea : mask.indices.map { max(mask[$0], hairArea[$0]) }
        let start = result.indices.map { target[$0] > 0 ? pasted[$0] : result[$0] }
        let prompt = "photo, \(colour ?? Self.colourWord(pasted, hair: hair)) hair, \(style), real hair strands, natural hairline, matte"
        let redrawn = try redraw(result, from: start, mask: target, prompt: prompt, negative: Self.hairNegative,
                                 strength: Self.strength, guidedPart: Self.guidedPart, seed: 7)
        report?(.finishing)
        result = Self.focused(redrawn.image, toMatch: photo, area: target, box: redrawn.box, w: w, h: h)

        guard let image = HairTryOn.makeImage(result, width: w, height: h) else { throw Failure.image }
        return image
    }

    /// Redraws `mask` of `canvas`, starting from `start`; only that area of the canvas changes.
    private func redraw(_ canvas: [SIMD3<Float>], from start: [SIMD3<Float>], mask: [Float], prompt: String, negative: String,
                        strength: Float, guidedPart: Float, seed: UInt64) throws -> (image: [SIMD3<Float>], box: Crop) {
        let w = HairTryOn.width, h = HairTryOn.height, n = Self.side, g = Self.grid
        let models = try loaded()
        guard let box = Self.cropBox(mask, w: w, h: h) else { return (canvas, Crop(x: 0, y: 0, side: n)) }

        // What the model sees: the crop, and the crop with the area to redraw blacked out.
        let picture = Self.take(start, box, w: w, h: h)
        let hole = Self.take(mask.map { SIMD3(repeating: $0) }, box, w: w, h: h).map { $0.x > 0.5 ? Float(1) : 0 }
        var whole = [Float](repeating: 0, count: 3 * n * n), kept = whole
        for i in 0..<(n * n) {
            for c in 0..<3 {
                let v = picture[i][c] * 2 - 1
                whole[c * n * n + i] = v
                kept[c * n * n + i] = hole[i] > 0 ? 0 : v
            }
        }
        let first = try encode(whole, models), around = try encode(kept, models)
        var hole64 = [Float](repeating: 0, count: g * g)
        for y in 0..<g { for x in 0..<g { hole64[y * g + x] = hole[y * 8 * n + x * 8] } }

        let wanted = try embedding(prompt, models), unwanted = try embedding(negative, models)

        // DPM-Solver++ (2M) over Karras noise levels; a partial strength starts part-way down them.
        let levels = Self.noiseLevels(Self.steps)
        let used = max(1, min(Self.steps, Int(Float(Self.steps) * strength)))
        let sigma = Array(levels[(Self.steps - used)...])
        let guided = guidedPart >= 1 ? used : max(1, Int((Float(used) * guidedPart).rounded()))
        var random = SplitMix(state: seed)
        let count = 4 * g * g
        var x = (0..<count).map { first[$0] + sigma[0] * Self.normal(&random) }
        var before: [Float]?
        for i in 0..<used {
            try Task.checkCancellation()
            let now = sigma[i], next = sigma[i + 1]
            let scale = 1 / (1 + now * now).squareRoot()
            let sample = x.map { $0 * scale } + hole64 + around
            let time = Self.timestep(for: now)
            var noise = try predict(sample, time, wanted, models)
            if i < guided {
                let plain = try predict(sample, time, unwanted, models)
                for k in 0..<count { noise[k] = plain[k] + Self.guidance * (noise[k] - plain[k]) }
            }
            let clean = (0..<count).map { x[$0] - now * noise[$0] }
            if next == 0 {
                x = clean
            } else {
                let stride = log(now) - log(next)
                var aim = clean
                if let before, i > 0 {
                    let r = (log(sigma[i - 1]) - log(now)) / stride
                    for k in 0..<count { aim[k] = (1 + 1 / (2 * r)) * clean[k] - (1 / (2 * r)) * before[k] }
                }
                let keep = next / now, move = -expm1(-stride)
                for k in 0..<count { x[k] = keep * x[k] + move * aim[k] }
            }
            before = clean
        }
        try Task.checkCancellation()
        let painted = try decode(x, models)

        // Back onto the canvas through a feathered copy of the mask.
        let feather = Self.gaussian(mask, w: w, h: h, sigma: 4)
        var out = canvas
        let perPixel = Float(n) / Float(box.side)
        for y in max(0, box.y)..<min(h, box.y + box.side) {
            for x in max(0, box.x)..<min(w, box.x + box.side) {
                let f = feather[y * w + x]
                guard f > 0.001 else { continue }
                let p = Self.bilinear(painted, (Float(x - box.x) + 0.5) * perPixel - 0.5, (Float(y - box.y) + 0.5) * perPixel - 0.5, n, n)
                out[y * w + x] = p * f + canvas[y * w + x] * (1 - f)
            }
        }
        return (out, box)
    }

    /// Hair the clear pass left or grew where there should be none: in the cleared area, away from the new hair.
    /// nil when there is too little to matter, or no way to tell.
    private static func leftoverHair(in picture: [SIMD3<Float>], clear: [Float], hairArea: [Float], w: Int, h: Int) -> [Float]? {
        guard let found = HairTryOn.hairMap(of: picture) else { return nil }
        let nearNew = HairTryOn.box(hairArea, width: w, height: h, radius: 10)
        let left = found.indices.map { found[$0] > 0.5 && clear[$0] > 0 && nearNew[$0] < 0.001 ? Float(1) : 0 }
        guard left.reduce(0, +) / Float(w * h) > leftoverOver else { return nil }
        let grown = HairTryOn.box(left, width: w, height: h, radius: 16)
        return grown.indices.map { grown[$0] > 0.001 && clear[$0] > 0 ? Float(1) : 0 }
    }

    // MARK: Model calls

    private func embedding(_ text: String, _ models: Models) throws -> [Float] {
        if let known = embeddings[text] { return known }
        let ids = models.tokenizer.encode(text).map(Float.init)
        let out = try Self.run(models.text, ["input_ids": (ids, [1, ClipTokenizer.length])], output: "last_hidden_state")
        // The encoder gives 77 × 768; the U-Net reads it as 768 × 1 × 77.
        let tokens = ClipTokenizer.length, width = out.count / tokens
        var turned = [Float](repeating: 0, count: out.count)
        for t in 0..<tokens { for c in 0..<width { turned[c * tokens + t] = out[t * width + c] } }
        embeddings[text] = turned
        return turned
    }

    /// A picture (3 × 512 × 512, −1…1) as latents (4 × 64 × 64).
    private func encode(_ picture: [Float], _ models: Models) throws -> [Float] {
        let out = try Self.run(models.encoder, ["x": (picture, [1, 3, Self.side, Self.side])], output: "latent")
        // The encoder gives a mean and a spread per value; the mean is the picture.
        return out.prefix(4 * Self.grid * Self.grid).map { $0 * Self.latentScale }
    }

    private func decode(_ latents: [Float], _ models: Models) throws -> [SIMD3<Float>] {
        let n = Self.side
        let out = try Self.run(models.decoder, ["z": (latents.map { $0 / Self.latentScale }, [1, 4, Self.grid, Self.grid])], output: "image")
        guard out.count == 3 * n * n else { throw Failure.model("解码结果大小不对") }
        return (0..<(n * n)).map { i in
            SIMD3(out[i], out[n * n + i], out[2 * n * n + i]) * 0.5 + SIMD3(repeating: 0.5)
        }
    }

    /// The noise the model finds in `sample` (9 × 64 × 64: latents, hole, surroundings) at `time`.
    private func predict(_ sample: [Float], _ time: Float, _ text: [Float], _ models: Models) throws -> [Float] {
        try Self.run(models.unet, ["sample": (sample, [1, 9, Self.grid, Self.grid]), "timestep": ([time], [1]),
                                   "encoder_hidden_states": (text, [1, text.count / ClipTokenizer.length, 1, ClipTokenizer.length])],
                     output: "noise_pred")
    }

    private static func run(_ model: MLModel, _ inputs: [String: (values: [Float], shape: [Int])], output: String) throws -> [Float] {
        do {
            var features: [String: MLMultiArray] = [:]
            for (name, input) in inputs {
                let plain = try MLMultiArray(shape: input.shape.map { NSNumber(value: $0) }, dataType: .float32)
                plain.withUnsafeMutableBytes { raw, _ in input.values.withUnsafeBytes { raw.copyMemory(from: $0) } }
                // Models converted for half precision take half-precision arrays.
                let wanted = model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint?.dataType ?? .float32
                features[name] = wanted == .float32 ? plain : MLMultiArray(concatenating: [plain], axis: 0, dataType: wanted)
            }
            let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
            guard let array = result.featureValue(for: output)?.multiArrayValue else { throw Failure.model("没有输出 \(output)") }
            let plain = MLMultiArray(concatenating: [array], axis: 0, dataType: .float32)
            return plain.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.model(error.localizedDescription)
        }
    }

    // MARK: Noise levels

    /// How noisy each of the 1000 training steps was, least first.
    private static let trained: [Float] = {
        let from = (0.00085).squareRoot(), to = (0.012).squareRoot()
        var kept = 1.0
        var out: [Float] = []
        for i in 0..<1000 {
            let beta = pow(from + (to - from) * Double(i) / 999, 2)
            kept *= 1 - beta
            out.append(Float(((1 - kept) / kept).squareRoot()))
        }
        return out
    }()

    /// Karras et al.'s spacing from the noisiest level to the cleanest, then zero.
    private static func noiseLevels(_ count: Int) -> [Float] {
        let high = pow(trained[999], 1 / 7), low = pow(trained[0], 1 / 7)
        return (0..<count).map { pow(high + Float($0) / Float(count - 1) * (low - high), 7) } + [0]
    }

    /// The training step whose noise is nearest `sigma`, which is what the model was taught to read.
    private static func timestep(for sigma: Float) -> Float {
        let above = trained.firstIndex { $0 >= sigma } ?? 999
        guard above > 0 else { return 0 }
        let low = log(trained[above - 1]), high = log(trained[above])
        let part = max(0, min(1, (log(sigma) - low) / (high - low)))
        return (Float(above - 1) + part).rounded()
    }

    private static func normal(_ random: inout SplitMix) -> Float {
        let a = max(random.unit(), 1e-12), b = random.unit()
        return Float((-2 * log(a)).squareRoot() * cos(2 * .pi * b))
    }

    // MARK: Pictures

    /// A square of the canvas; it may reach past the edges, where the edge pixels repeat.
    private struct Crop { let x: Int, y: Int, side: Int }

    /// The masked area with a margin of surroundings for the model to match.
    private static func cropBox(_ mask: [Float], w: Int, h: Int) -> Crop? {
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] > 0.5 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x1 >= 0 else { return nil }
        let margin = Int(Float(max(x1 - x0, y1 - y0) + 1) * 0.1)
        x0 = max(0, x0 - margin); y0 = max(0, y0 - margin); x1 = min(w - 1, x1 + margin); y1 = min(h - 1, y1 + margin)
        let side = max(x1 - x0, y1 - y0) + 1
        func origin(_ low: Int, _ high: Int, _ limit: Int) -> Int {
            side <= limit ? max(0, min(limit - side, (low + high + 1 - side) / 2)) : (limit - side) / 2
        }
        return Crop(x: origin(x0, x1, w), y: origin(y0, y1, h), side: side)
    }

    /// The crop at the model's size, averaging where it is shrunk.
    private static func take(_ pixels: [SIMD3<Float>], _ crop: Crop, w: Int, h: Int) -> [SIMD3<Float>] {
        let n = side, step = Float(crop.side) / Float(n)
        let taps = step > 1.5 ? 3 : (step > 1.05 ? 2 : 1)
        var out = [SIMD3<Float>](repeating: .zero, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                var sum = SIMD3<Float>.zero
                for b in 0..<taps {
                    for a in 0..<taps {
                        sum += bilinear(pixels, Float(crop.x) + (Float(i) + (Float(a) + 0.5) / Float(taps)) * step - 0.5,
                                        Float(crop.y) + (Float(j) + (Float(b) + 0.5) / Float(taps)) * step - 0.5, w, h)
                    }
                }
                out[j * n + i] = sum / Float(taps * taps)
            }
        }
        return out
    }

    private static func bilinear(_ p: [SIMD3<Float>], _ x: Float, _ y: Float, _ w: Int, _ h: Int) -> SIMD3<Float> {
        let cx = max(0, min(Float(w - 1), x)), cy = max(0, min(Float(h - 1), y))
        let x0 = min(w - 2, Int(cx)), y0 = min(h - 2, Int(cy))
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let a = y0 * w + x0
        return (p[a] * (1 - fx) + p[a + 1] * fx) * (1 - fy) + (p[a + w] * (1 - fx) + p[a + w + 1] * fx) * fy
    }

    private static func gaussian(_ v: [Float], w: Int, h: Int, sigma: Float) -> [Float] {
        guard sigma > 0.05 else { return v }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var across = [Float](repeating: 0, count: v.count), out = across
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0
                for k in -radius...radius { sum += kernel[k + radius] * v[y * w + max(0, min(w - 1, x + k))] }
                across[y * w + x] = sum
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0
                for k in -radius...radius { sum += kernel[k + radius] * across[max(0, min(h - 1, y + k)) * w + x] }
                out[y * w + x] = sum
            }
        }
        return out
    }

    /// The redrawn area brought to the sharpness of the photo around it. The model draws the whole head in
    /// 512 pixels, usually fewer than the canvas gives it, so its hair tends to come out softer than a sharp photo
    /// and painted-looking: then fine contrast is put back. On a soft photo it is the other way round, the hair
    /// would sit on it like a sticker, and it is blurred instead.
    /// (Drawing the hair again a quarter at a time, enlarged, was tried for the first case: the model paints
    /// bigger, smoother locks, not finer strands.)
    private static func focused(_ result: [SIMD3<Float>], toMatch photo: [SIMD3<Float>], area: [Float], box: Crop,
                                w: Int, h: Int) -> [SIMD3<Float>] {
        // Judged inside the crop only, which is where the hair is.
        let x0 = max(0, box.x), y0 = max(0, box.y), bw = min(w, box.x + box.side) - x0, bh = min(h, box.y + box.side) - y0
        guard bw > 8, bh > 8 else { return result }
        func cut<T>(_ v: [T]) -> [T] { (0..<(bw * bh)).map { v[(y0 + $0 / bw) * w + x0 + $0 % bw] } }
        let luma = { (p: SIMD3<Float>) in 0.299 * p.x + 0.587 * p.y + 0.114 * p.z }
        let inside = cut(area).map { $0 > 0.5 }
        guard inside.filter({ $0 }).count > 500 else { return result }

        /// How much of the detail is fine rather than coarse: high for a sharp picture, whatever its contrast.
        func fineness(_ light: [Float], where region: [Bool]?) -> Float {
            let fine = gaussian(light, w: bw, h: bh, sigma: 1.2), coarse = gaussian(light, w: bw, h: bh, sigma: 3.6)
            var small: Float = 0, large: Float = 0
            for i in light.indices where region?[i] ?? true {
                small += abs(light[i] - fine[i]); large += abs(fine[i] - coarse[i])
            }
            return small / (large + 1e-6)
        }
        let want = fineness(cut(photo).map(luma), where: nil)
        let part = cut(result), light = part.map(luma)
        let have = fineness(light, where: inside)
        let blend = gaussian(cut(area), w: bw, h: bh, sigma: 4)
        var out = result

        if have > want * 1.1 {
            var low: Float = 0, high: Float = 4
            for _ in 0..<6 {
                let middle = (low + high) / 2
                if fineness(gaussian(light, w: bw, h: bh, sigma: middle), where: inside) > want * 1.1 { low = middle } else { high = middle }
            }
            let soft = (0..<3).map { c in gaussian(part.map { $0[c] }, w: bw, h: bh, sigma: high) }
            for i in 0..<(bw * bh) where blend[i] > 0.001 {
                let at = (y0 + i / bw) * w + x0 + i % bw
                out[at] = SIMD3(soft[0][i], soft[1][i], soft[2][i]) * blend[i] + result[at] * (1 - blend[i])
            }
        } else if have < want {
            // What a slight blur takes away is the fine detail; add more of it until it is as fine as the photo's.
            let blurred = (0..<3).map { c in gaussian(part.map { $0[c] }, w: bw, h: bh, sigma: 1.2) }
            let detail = part.indices.map { part[$0] - SIMD3(blurred[0][$0], blurred[1][$0], blurred[2][$0]) }
            let lightDetail = detail.map(luma)
            var low: Float = 0, high = sharpenAtMost
            for _ in 0..<6 {
                let middle = (low + high) / 2
                if fineness(light.indices.map { light[$0] + middle * lightDetail[$0] }, where: inside) < want { low = middle } else { high = middle }
            }
            for i in 0..<(bw * bh) where blend[i] > 0.001 {
                let at = (y0 + i / bw) * w + x0 + i % bw
                let sharp = simd_clamp(part[i] + detail[i] * high, SIMD3(repeating: 0), SIMD3(repeating: 1))
                out[at] = sharp * blend[i] + result[at] * (1 - blend[i])
            }
        }
        return out
    }

    /// A plain word for the hair colour of the draft, for the prompt.
    private static func colourWord(_ pixels: [SIMD3<Float>], hair: [Float]) -> String {
        let found = pixels.indices.filter { hair[$0] > 0.78 }
        guard found.count >= 500 else { return "dark" }
        let sample = stride(from: 0, to: found.count, by: max(1, found.count / 4000)).map { pixels[found[$0]] }
        let middle = sample.count / 2
        let r = sample.map(\.x).sorted()[middle], g = sample.map(\.y).sorted()[middle], b = sample.map(\.z).sorted()[middle]
        let light = 0.299 * r + 0.587 * g + 0.114 * b
        // Past the draft's strength the model takes the colour from this word more than from the draft.
        if light < 0.16 { return max(r, g, b) - min(r, g, b) < 0.1 ? "black" : (r > b * 2.5 ? "dark reddish brown" : "dark brown") }
        if max(r, g, b) - min(r, g, b) < 0.06 { return light < 0.4 ? "dark grey" : (light < 0.65 ? "grey" : "silver white") }
        if light < 0.3 { return "dark brown" }
        if light < 0.5 { return r > b * 1.9 ? "auburn" : "brown" }
        return "blonde"
    }

    private static func pixels(_ image: CGImage, _ w: Int, _ h: Int) -> [SIMD3<Float>]? {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return (0..<(w * h)).map { SIMD3(Float(bytes[$0 * 4]), Float(bytes[$0 * 4 + 1]), Float(bytes[$0 * 4 + 2])) / 255 }
    }
}
