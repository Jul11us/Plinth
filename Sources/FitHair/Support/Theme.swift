import SwiftUI
import AppKit

/// Colours taken from the FitHair design canvas.
enum Theme {
    static let ink = Color(hex: 0x0A0A0A)
    static let paper = Color(hex: 0xE9E9E6)
    static let stone = Color(hex: 0xDCDAD7)
    static let accent = Color(hex: 0xFF5A1F)
    static let muted = Color(hex: 0x3A3A3A)
    /// Corner radius shared by every card in the app.
    static let cardRadius: CGFloat = 14
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Locates bundled resources both when run from `swift run`/Xcode and from the packaged .app.
enum Res {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("FitHair_FitHair.bundle"),
           let b = Bundle(url: url) {
            return b
        }
        return Bundle.module
    }()

    static func url(_ name: String, _ ext: String) -> URL? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }

    static func hasImage(_ name: String) -> Bool { url(name, "jpg") != nil }

    static func image(_ name: String) -> NSImage {
        if let url = url(name, "jpg"), let img = NSImage(contentsOf: url) { return img }
        return NSImage(size: NSSize(width: 4, height: 5))
    }
}
