import SwiftUI

/// White museum-label card, the same object as on the home page.
struct LabelCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}

/// Expensive artwork made once, that can be let go of while no window needs it and made again later.
final class Reloadable<Value: Sendable>: @unchecked Sendable {
    private let make: @Sendable () async -> Value
    private let lock = NSLock()
    private var task: Task<Value, Never>?

    init(_ make: @escaping @Sendable () async -> Value) { self.make = make }

    var value: Task<Value, Never> {
        lock.withLock {
            if let task { return task }
            let started = Task.detached(priority: .userInitiated, operation: make)
            task = started
            return started
        }
    }

    func release() { lock.withLock { task = nil } }
}

/// Black capsule — the one primary action on a screen.
struct CapsuleButton: View {
    let title: String
    var systemImage: String?
    var enabled = true
    /// Stretch to the width offered (for a column of equal-width buttons).
    var expand = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(maxWidth: expand ? .infinity : nil)
            .frame(height: 40)
            .background(enabled ? Theme.ink : Color(hex: 0x9A9894), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Quiet secondary action: text with an optional symbol.
struct QuietButton: View {
    let title: String
    var systemImage: String?
    var expand = false
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .frame(maxWidth: expand ? .infinity : nil)
            .frame(height: 34)
            .background(Color.white.opacity(hovered ? 0.95 : 0.7), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovered)
    }
}

/// A hairstyle's bust photo, filling whatever frame it is given; a quiet placeholder when the photo
/// hasn't been generated yet (see scripts/hairstyle-prompts.py).
struct StyleImage: View {
    let style: Hairstyle
    var angle: BustAngle = .front

    /// The pictures are framed anything from whole bust to close-up; this evens out how big the head looks.
    /// Long styles keep more of the picture so their length still shows.
    private var tightest: CGFloat {
        switch style.length {
        case .short: 0.54
        case .medium: 0.66
        case .long: style.gender == .male ? 0.66 : 0.78     // men's "long" stops around the jaw
        }
    }

    var body: some View {
        let name = style.imageName(for: angle)
        ZStack {
            if Res.hasImage(name) {
                GeometryReader { g in
                    if g.size.width > 0, g.size.height > 0 {
                        let window = BustBand.hairWindow(name, aspect: g.size.width / g.size.height, tightest: tightest)
                        let height = g.size.height / window.height
                        let width = height * 0.8
                        Image(nsImage: Res.image(name))
                            .resizable()
                            .frame(width: width, height: height)
                            .position(x: width / 2 - window.minX * width, y: height / 2 - window.minY * height)
                    }
                }
            } else {
                Theme.paper
                VStack(spacing: 6) {
                    Image(systemName: "scissors").font(.system(size: 22, weight: .light)).foregroundStyle(Color.fhTertiary)
                    Text(style.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.fhSecondary)
                        .multilineTextAlignment(.center)
                    Text("示意图待生成").font(.system(size: 10)).foregroundStyle(Color.fhTertiary)
                }
                .padding(8)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Short confirmation shown at the bottom of a screen for a couple of seconds.
struct Toast: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 34)
            .background(Theme.ink.opacity(0.88), in: Capsule())
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension Font {
    static let fhTitle = Font.system(size: 30, weight: .semibold)
    static let fhHeading = Font.system(size: 20, weight: .semibold)
    static let fhBody = Font.system(size: 14)
    static let fhSmall = Font.system(size: 12)
}

extension Color {
    static let fhSecondary = Color(hex: 0x5E5C58)
    static let fhTertiary = Color(hex: 0x8A8884)
}
