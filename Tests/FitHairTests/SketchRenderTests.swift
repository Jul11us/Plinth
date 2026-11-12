import XCTest
import SwiftUI
@testable import FitHair

/// Renders the measurement sketch for each bust to PNG so the drawing can be checked by eye.
final class SketchRenderTests: XCTestCase {
    @MainActor func testRenderSketches() throws {
        let out = ProcessInfo.processInfo.environment["SKETCH_OUT"] ?? NSTemporaryDirectory()
        for shape in ["oval", "round", "square", "heart", "oblong", "diamond", "triangle"] {
            let url = try XCTUnwrap(Res.url("shape-\(shape)", "jpg"))
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            let m = try FaceAnalyzer.analyze(img)
            let view = MeasuredPhoto(image: img, measurement: m, still: true).frame(width: 440, height: 550)
            let r = ImageRenderer(content: view); r.scale = 2
            let cg = try XCTUnwrap(r.cgImage)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("sketch-\(shape).png"))
        }
    }

    /// The exported card goes through ImageRenderer, which draws controls it can't render as yellow blocks.
    @MainActor func testBarberCardExportRenders() throws {
        let out = ProcessInfo.processInfo.environment["SKETCH_OUT"] ?? NSTemporaryDirectory()
        for id in ["f1", "m6"] {         // an ordinary bust and a tightly framed one
            let style = try XCTUnwrap(Hairstyle.all.first { $0.id == id })
            let r = ImageRenderer(content: BarberCard(style: style, shape: .oval, leaning: nil, hasResult: true)
                .frame(width: 440).padding(20).background(Theme.stone))
            r.scale = 2
            let cg = try XCTUnwrap(r.cgImage)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("barber-\(id).png"))
        }
    }

    /// Every style ships three views, and the card's crop of each stays inside the picture.
    @MainActor func testEveryStyleHasThreeFramedViews() throws {
        let out = ProcessInfo.processInfo.environment["SKETCH_OUT"] ?? NSTemporaryDirectory()
        for style in Hairstyle.all {
            XCTAssertTrue(style.hasAllViews, "\(style.id) is missing a side or back picture")
            for name in [style.imageName, style.sideImageName, style.backImageName] {
                let window = BustBand.hairWindow(name, aspect: 0.74)
                XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -0.001, dy: -0.001).contains(window), name)
                XCTAssertEqual(window.width * 0.8 / window.height, 0.74, accuracy: 0.001, name)
            }
        }
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.fixed(330), spacing: 14), count: 4), spacing: 14) {
            ForEach(Hairstyle.all) { BustViews(style: $0) }
        }.padding(14).frame(width: 1400).background(Color.white)
        let r = ImageRenderer(content: grid); r.scale = 1.3
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(r.cgImage)).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("views-all.png"))

        let library = LazyVGrid(columns: Array(repeating: GridItem(.fixed(180), spacing: 10), count: 8), spacing: 10) {
            ForEach(Hairstyle.all) { StyleImage(style: $0).frame(width: 180, height: 225) }
        }.padding(10).frame(width: 1530).background(Color.white)
        let tiles = ImageRenderer(content: library); tiles.scale = 1
        let tileData = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(tiles.cgImage)).representation(using: .png, properties: [:]))
        try tileData.write(to: URL(fileURLWithPath: out).appendingPathComponent("library-all.png"))
    }

    /// The on-screen card has to fit the smallest window without scrolling, whatever the style says.
    @MainActor func testWideCardFitsTheWindow() throws {
        let out = ProcessInfo.processInfo.environment["SKETCH_OUT"] ?? NSTemporaryDirectory()
        let available: CGFloat = 640       // 720 minimum window, less the title bar and margins
        var tallest: (id: String, height: CGFloat) = ("", 0)
        for style in Hairstyle.all {
            let card = BarberCard(style: style, shape: .oval, hasResult: true, goal: FaceShape.oval.barberGoal(for: style.gender), wide: true)
                .frame(width: 744).background(Theme.stone)
            let r = ImageRenderer(content: card); r.scale = 2
            let cg = try XCTUnwrap(r.cgImage)
            let height = CGFloat(cg.height) / 2
            if height > tallest.height { tallest = (style.id, height) }
            XCTAssertLessThanOrEqual(height, available, "\(style.id) doesn't fit the window")
            if ["f1", "m6"].contains(style.id) {
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("wide-\(style.id).png"))
            }
        }
        print("WIDE tallest \(tallest.id) \(tallest.height)")
    }

    /// The phone export has to fit one iPhone screen in the common case, and the combined sheet has to render.
    @MainActor func testPhoneCardAndCombinedSheet() throws {
        let out = ProcessInfo.processInfo.environment["SKETCH_OUT"] ?? NSTemporaryDirectory()
        func write(_ view: some View, _ name: String) throws -> CGImage {
            let r = ImageRenderer(content: view); r.scale = 3
            let cg = try XCTUnwrap(r.cgImage)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
            return cg
        }
        let dye = ColourAdvisor.cardRows(shade: HairTryOn.Shade.all.first { $0.id == "milktea" }!, profile: ColourProfile(hairLevel: 2))
        let hair = HairPreferences(density: .thick, strand: .fine, currentLength: .long, treatment: .dyed).currentHair
        let female = try XCTUnwrap(Hairstyle.all.first { $0.id == "f1" }), male = try XCTUnwrap(Hairstyle.all.first { $0.id == "m6" })
        for style in [female, male] {
            let card = BarberCard(style: style, shape: .oval, hasResult: true, dye: dye, goal: FaceShape.oval.barberGoal(for: style.gender),
                                  currentHair: hair, phone: true, imageHeight: 200)
                .frame(width: BarberCard.phoneSize.width).frame(minHeight: BarberCard.phoneSize.height, alignment: .top).background(Color.white)
            let image = try write(card, "phone-\(style.id).png")
            XCTAssertLessThanOrEqual(CGFloat(image.height) / 3, BarberCard.phoneSize.height, "\(style.id) doesn't fit one screen")
        }
        let saved = Array(Hairstyle.all.filter { $0.gender == .female }.prefix(4))
        _ = try write(BarberSheet(styles: saved, goal: FaceShape.oval.barberGoal(for: .female), currentHair: hair, dye: dye)
            .frame(width: BarberCard.phoneSize.width).background(Color.white), "sheet.png")
    }
}
