import XCTest
@testable import FitHair

final class HairTryOnTests: XCTestCase {
    private func load(_ name: String) throws -> CGImage {
        let url = try XCTUnwrap(Res.url(name, "jpg"))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(AppState.uprightImage(from: src))
    }

    /// Writes previews to TRYON_OUT when set, so the results can be judged by eye.
    func testEveryStyleRendersOnEveryBust() throws {
        let out = ProcessInfo.processInfo.environment["TRYON_OUT"]
        for person in out == nil ? ["shape-oval"] : ["shape-oval", "shape-square"] {
            let photo = try load(person)
            let face = try FaceAnalyzer.analyze(photo)
            for style in Hairstyle.all where Res.hasImage(style.imageName) {
                let bust = try load(style.imageName)
                let result: HairTryOn.Output
                do {
                    result = try HairTryOn.render(photo: photo, face: face, bust: bust,
                                                  bustFace: try FaceAnalyzer.analyze(bust), shade: HairTryOn.Shade.all[2])
                } catch HairTryOn.Failure.tooShort {
                    XCTAssertFalse(style.hairProfile.supportsTryOn, "\(style.id) should be previewable")
                    continue
                }
                XCTAssertTrue(style.hairProfile.supportsTryOn, "\(style.id) can render and should offer photo previews")
                XCTAssertEqual(result.image.width, 960)
                XCTAssertEqual(result.image.height, 1200)
                if let out {
                    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: result.image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
                    try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(person)-\(style.id).jpg"))
                }
            }
        }
    }

    /// Every colour on one style, for judging the palette by eye. Only runs when TRYON_OUT is set.
    func testPaletteSheet() throws {
        guard let out = ProcessInfo.processInfo.environment["TRYON_OUT"] else { return }
        // TRYON_PHOTO swaps the sitter, e.g. for a picture with real skin colour.
        let photo: CGImage
        if let path = ProcessInfo.processInfo.environment["TRYON_PHOTO"] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
            photo = try XCTUnwrap(AppState.uprightImage(from: source))
        } else {
            photo = try load("shape-oval")
        }
        let bust = try load("hair-f1")
        let face = try FaceAnalyzer.analyze(photo), bustFace = try FaceAnalyzer.analyze(bust)
        for shade in HairTryOn.Shade.all {
            let result = try HairTryOn.render(photo: photo, face: face, bust: bust, bustFace: bustFace, shade: shade)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: result.image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("shade-\(shade.id).jpg"))
        }
    }

    /// The busts look to different sides. The hair has to end up where it would be on a head turned like the
    /// sitter's: slid across the face, and taken from the bust's mirror image when the two face opposite ways.
    func testHairFollowsTheWayTheHeadIsTurned() throws {
        let right = try load("hair-m4"), left = try load("hair-m6"), ahead = try load("hair-m9"), farLeft = try load("hair-f2")
        let rightFace = try FaceAnalyzer.analyze(right)
        XCTAssertGreaterThan(rightFace.turn, 0.1)
        XCTAssertLessThan(try FaceAnalyzer.analyze(left).turn, -0.05)
        XCTAssertLessThan(abs(try FaceAnalyzer.analyze(ahead).turn), 0.05)

        /// Where the middle of the new hair is, across the canvas.
        func hairMiddle(on sitter: CGImage, matchTurn: Bool) throws -> Double {
            let result = try HairTryOn.render(photo: sitter, face: try FaceAnalyzer.analyze(sitter), bust: right, bustFace: rightFace,
                                              shade: .auto, forRepaint: true, matchTurn: matchTurn)
            let matte = try XCTUnwrap(result.repaint?.hair), w = matte.width, h = matte.height
            var bytes = [UInt8](repeating: 0, count: w * h)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.draw(matte, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sum = 0.0, weight = 0.0
            for i in bytes.indices where bytes[i] > 127 { sum += Double(i % w); weight += 1 }
            return sum / max(1, weight)
        }
        // A bust looking right has its hair to the left of its face. Facing ahead, or left, it belongs further right.
        for sitter in [ahead, farLeft] {
            XCTAssertGreaterThan(try hairMiddle(on: sitter, matchTurn: true), try hairMiddle(on: sitter, matchTurn: false) + 15)
        }
    }

    /// The try-on paints from a description of the hair. Where the bust doesn't look like the recipe it was made
    /// from, the record says what it does look like, and that is what the try-on is given.
    func testTheTryOnIsToldWhatTheBustLooksLike() {
        let styles = Dictionary(uniqueKeysWithValues: Hairstyle.all.map { ($0.id, $0) })
        XCTAssertEqual(styles["m4"]?.tryOnPrompt, styles["m4"]?.prompt)
        let quiff = styles["m6"]
        XCTAssertNotEqual(quiff?.tryOnPrompt, quiff?.prompt)
        XCTAssertTrue(quiff?.tryOnPrompt.contains("chunky pieces") ?? false)
        // With the colour and the fixed words around it, it has to fit in the 77 tokens the model reads.
        for style in Hairstyle.all { XCTAssertLessThan(style.tryOnPrompt.split(separator: " ").count, 40, style.id) }
    }

    /// A fringe is read against the eyebrows, and the busts have theirs lower than people do: the bust's brows
    /// go onto the sitter's, so a fringe that leaves forehead showing on the bust leaves some on the sitter.
    func testTheBrowsAreMeasuredForPlacingAFringe() throws {
        for name in ["hair-m7", "hair-m9", "shape-oval"] {
            let face = try FaceAnalyzer.analyze(try load(name))
            let brows = try XCTUnwrap(face.brows, name)
            XCTAssertEqual(brows.count, 3, name)
            let pupils = (face.keyPoints.pupilLeft.y + face.keyPoints.pupilRight.y) / 2
            for brow in brows {
                XCTAssertLessThan(brow.y, pupils, name)
                XCTAssertGreaterThan(brow.y, face.keyPoints.hairline.y, name)
            }
            XCTAssertLessThan(brows[0].x, brows[2].x, name)
        }
    }

    /// A fade leaves the sides too short to cover the scalp. Painted as full hair they come out as a block of the
    /// hair colour, which shows most with a dye.
    func testFadedSidesShowTheScalp() throws {
        let styles = Dictionary(uniqueKeysWithValues: Hairstyle.all.map { ($0.id, $0) })
        XCTAssertEqual(styles["m6"]?.fadeHeight, 1.05)      // high skin fade
        XCTAssertEqual(styles["m2"]?.fadeHeight, 0.75)      // mid fade
        XCTAssertEqual(styles["m3"]?.fadeHeight, 0.45)      // low fade
        // A perm is cut with a low fade too, under curls that cover it.
        XCTAssertNil(styles["m9"]?.fadeHeight)
        XCTAssertNil(styles["m4"]?.fadeHeight)
        XCTAssertNil(styles["f2"]?.fadeHeight)
        // A French crop is cut with a fade, but its top hangs over it: seen from the front there is none to show.
        XCTAssertTrue(styles["m7"]?.prompt.contains("fade") ?? false)
        XCTAssertNil(styles["m7"]?.fadeHeight)

        let sitter = try load("hair-m9"), bust = try load("hair-m6")
        let face = try FaceAnalyzer.analyze(sitter), bustFace = try FaceAnalyzer.analyze(bust)
        let black = try XCTUnwrap(HairTryOn.Shade.all.first { $0.id == "black" })
        let w = HairTryOn.width, h = HairTryOn.height
        func light(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: w * h)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return bytes
        }
        let full = try HairTryOn.render(photo: sitter, face: face, bust: bust, bustFace: bustFace, shade: black, forRepaint: true)
        let faded = try HairTryOn.render(photo: sitter, face: face, bust: bust, bustFace: bustFace, shade: black, forRepaint: true,
                                         fadeHeight: styles["m6"]?.fadeHeight)
        let hair = try light(try XCTUnwrap(full.repaint?.hair)), before = try light(full.image), after = try light(faded.image)
        // Beside the eyes, where the hair is: black before, lighter with the scalp showing.
        var was = 0, now = 0, count = 0
        for y in 400..<470 {
            for x in 0..<w where abs(x - w / 2) > 150 && hair[y * w + x] > 200 { was += Int(before[y * w + x]); now += Int(after[y * w + x]); count += 1 }
        }
        XCTAssertGreaterThan(count, 300)
        XCTAssertGreaterThan(now / count, was / count + 25)
        // The top of the head is as it was.
        var changed = 0
        for y in 0..<250 { for x in 0..<w where before[y * w + x] != after[y * w + x] { changed += 1 } }
        XCTAssertEqual(changed, 0)
    }

    /// The repaint grows the hair on the sitter's own head, so it is handed the skin the hair meets as well:
    /// forehead and temples, never the eyes, brows, nose or mouth.
    func testRepaintAlsoGetsTheSkinTheHairMeets() throws {
        let sitter = try load("hair-m9"), bust = try load("hair-m6")
        let result = try HairTryOn.render(photo: sitter, face: try FaceAnalyzer.analyze(sitter), bust: bust,
                                          bustFace: try FaceAnalyzer.analyze(bust), shade: .auto, forRepaint: true)
        let extra = try XCTUnwrap(result.repaint), w = HairTryOn.width, h = HairTryOn.height
        func values(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: w * h)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return bytes
        }
        let blend = try values(extra.blend), hair = try values(extra.hair)
        XCTAssertGreaterThan(blend.filter { $0 > 127 }.count, 2000)
        // The canvas has the pupils 158 px apart at y 470: from the brows to the mouth nothing is handed over.
        for y in 410..<640 {
            for x in (w / 2 - 120)..<(w / 2 + 120) { XCTAssertLessThan(blend[y * w + x], 128, "at \(x), \(y)") }
        }
        // And it stays next to the hair.
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) where blend[y * w + x] > 127 {
                let near = (max(0, y - 40)...min(h - 1, y + 40)).contains { yy in
                    stride(from: max(0, x - 40), through: min(w - 1, x + 40), by: 4).contains { hair[yy * w + $0] > 12 }
                }
                XCTAssertTrue(near, "at \(x), \(y)")
            }
        }
    }

    /// How long the waits of a try-on are, with the installed model: loading it, the first picture of a style, and
    /// another colour of the same style, which reuses what was redrawn behind the old hair. Only with REPAINT_TIME
    /// set to a photo.
    func testRepaintWaits() async throws {
        guard let path = ProcessInfo.processInfo.environment["REPAINT_TIME"], HairRepaint.isInstalled else { return }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let photo = try XCTUnwrap(AppState.uprightImage(from: source))
        let face = try FaceAnalyzer.analyze(photo)
        func seconds(_ work: () async throws -> Void) async rethrows -> String {
            let began = Date()
            try await work()
            return String(format: "%.1f s", Date().timeIntervalSince(began))
        }
        print("WAIT loading the model: " + (await seconds { await HairRepaint.shared.prepare() }))
        for id in ["m6", "m4"] {
            let style = try XCTUnwrap(Hairstyle.all.first { $0.id == id })
            let bust = try load(style.imageName), bustFace = try FaceAnalyzer.analyze(bust)
            var pictures: [CGImage] = []
            for shadeID in ["auto", "wine", "blonde"] {
                let shade = try XCTUnwrap(HairTryOn.Shade.all.first { $0.id == shadeID })
                let draft = try HairTryOn.render(photo: photo, face: face, bust: bust, bustFace: bustFace, shade: shade, forRepaint: true,
                                                 fadeHeight: style.fadeHeight)
                let took = try await seconds {
                    pictures.append(try await HairRepaint.shared.render(draft, style: style.tryOnPrompt, colour: shade.promptName, scene: id))
                }
                print("WAIT \(id) \(shadeID): \(took)")
            }
            if let out = ProcessInfo.processInfo.environment["REPAINT_OUT"] {
                for (picture, name) in zip(pictures, ["auto", "wine", "blonde"]) {
                    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("wait-\(id)-\(name).png"))
                }
            }
        }
    }

    /// Writes what a generative repaint needs for every photo in REPAINT_PHOTOS (a folder) and every style in
    /// REPAINT_STYLES (ids, comma separated) to REPAINT_OUT: the photo, the pasted draft, the masks and the prompt.
    func testRepaintInputs() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["REPAINT_OUT"], let folder = env["REPAINT_PHOTOS"] else { return }
        let ids = (env["REPAINT_STYLES"] ?? "m1").split(separator: ",").map(String.init)
        // REPAINT_SHADE picks a colour by id; the second line of the prompt file is its name for the image model.
        let shade = HairTryOn.Shade.all.first { $0.id == env["REPAINT_SHADE"] } ?? .auto
        let suffix = shade.id == "auto" ? "" : "-\(shade.id)"
        let files = try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
            .filter { ["jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }
        func write(_ image: CGImage, _ name: String) throws {
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
        }
        print("REPAINT busts turn: " + Hairstyle.all.compactMap { style in
            (try? load(style.imageName)).flatMap { try? FaceAnalyzer.analyze($0) }.map { "\(style.id) \(String(format: "%+.3f", $0.turn))" }
        }.joined(separator: ", "))
        for file in files {
            let person = (file as NSString).deletingPathExtension
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: folder).appendingPathComponent(file) as CFURL, nil))
            let photo = try XCTUnwrap(AppState.uprightImage(from: source))
            let face: FaceMeasurement
            do { face = try FaceAnalyzer.analyze(photo) } catch { print("REPAINT \(person): no face — \(error.localizedDescription)"); continue }
            print("REPAINT \(person): cheeks \(Int(face.cheekWidth)) px, roll \(Int(face.roll))°, turn \(String(format: "%+.3f", face.turn)), warnings \(face.warnings)")
            for id in ids {
                guard let style = Hairstyle.all.first(where: { $0.id == id }) else { continue }
                let bust = try load(style.imageName)
                do {
                    let result = try HairTryOn.render(photo: photo, face: face, bust: bust, bustFace: try FaceAnalyzer.analyze(bust),
                                                      shade: shade, forRepaint: true, matchTurn: env["REPAINT_NO_MIRROR"] == nil,
                                                      fadeHeight: env["REPAINT_NO_FADE"] == nil ? style.fadeHeight : nil)
                    let extra = try XCTUnwrap(result.repaint)
                    try write(result.original, "\(person)-\(id)\(suffix)-photo.png")
                    try write(result.image, "\(person)-\(id)\(suffix)-draft.png")
                    try write(extra.mask, "\(person)-\(id)\(suffix)-mask.png")
                    try write(extra.hair, "\(person)-\(id)\(suffix)-hair.png")
                    try write(extra.blend, "\(person)-\(id)\(suffix)-blend.png")
                    // REPAINT_RUN also redraws the hair with the installed model, the way the app does.
                    if env["REPAINT_RUN"] != nil, HairRepaint.isInstalled {
                        let began = Date()
                        try write(try await HairRepaint.shared.render(result, style: style.tryOnPrompt, colour: shade.promptName),
                                  "\(person)-\(id)\(suffix)-coreml.png")
                        print("REPAINT \(person) \(id)\(suffix): redrawn in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
                    }
                    try (style.tryOnPrompt + "\n" + (shade.promptName ?? "")).write(
                        toFile: (out as NSString).appendingPathComponent("\(person)-\(id)\(suffix)-prompt.txt"), atomically: true, encoding: .utf8)
                } catch { print("REPAINT \(person) \(id): \(error.localizedDescription)") }
            }
        }
    }

    /// The tokenizer has to agree with the one the model was trained with. CLIP_REFERENCE is a JSON list of
    /// {text, ids} made with the reference tokenizer; needs the repaint model installed for its vocabulary.
    func testTokenizerMatchesReference() throws {
        guard let path = ProcessInfo.processInfo.environment["CLIP_REFERENCE"], HairRepaint.isInstalled else { return }
        struct Case: Decodable { let text: String; let ids: [Int] }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let tokenizer = try ClipTokenizer(vocabulary: HairRepaint.folder.appendingPathComponent("vocab.json"),
                                          merges: HairRepaint.folder.appendingPathComponent("merges.txt"))
        XCTAssertFalse(cases.isEmpty)
        for c in cases { XCTAssertEqual(tokenizer.encode(c.text), c.ids, c.text) }
    }
}
