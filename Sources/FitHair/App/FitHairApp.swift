import SwiftUI
import AppKit

@main
struct FitHairApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var state: AppState { appDelegate.state }

    var body: some Scene {
        Window("Plinth", id: AppDelegate.mainWindowID) {
            MainWindowContent(delegate: appDelegate)
                .environment(state)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新的分析") { state.startOver() }.keyboardShortcut("n")
                Button("打开照片…") { state.pickPhoto() }.keyboardShortcut("o")
            }
        }
    }
}

private struct MainWindowContent: View {
    let delegate: AppDelegate
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .onAppear {
                delegate.reopenWindow = { openWindow(id: AppDelegate.mainWindowID) }
                // Testing hook: `Plinth -analyze /path/to/photo.jpg` analyses a photo straight away.
                let args = CommandLine.arguments
                if let i = args.firstIndex(of: "-analyze"), i + 1 < args.count {
                    state.load(url: URL(fileURLWithPath: args[i + 1]))
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    let state = AppState(lastResult: .onDisk, reminder: SystemTrimReminder())
    private var statusBar: StatusBarController?
    /// SwiftUI's way of bringing the window back once it has been closed.
    fileprivate var reopenWindow: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Start baking the word now, so the opening doesn't wait on a blank wall.
        _ = HairWordArt.shared
        _ = HairWordArt.finished
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched as a bare executable (swift run / Xcode), make it a regular foreground app with the icon.
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        statusBar = StatusBarController(state: state) { [weak self] in self?.showMainWindow() }
        // Testing hook: `Plinth -open-status-panel` opens the menu-bar panel shortly after launch.
        if CommandLine.arguments.contains("-open-status-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.statusBar?.toggle() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { if let window, Self.isMain(window) { self?.mainWindowWillClose() } }
        }
    }

    /// Opening Plinth again while it sits in the menu bar brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !state.residesInMenuBar }

    private static func isMain(_ window: NSWindow) -> Bool { window.canBecomeMain && !(window is NSPanel) }

    /// Staying in the menu bar: no Dock icon, and none of the heavy artwork kept around.
    private func mainWindowWillClose() {
        guard state.residesInMenuBar else { return }
        NSApp.setActivationPolicy(.accessory)
        state.releaseForBackground()
        HairWordArt.releaseArtwork()
        MorphPlayer.releaseExhibit()
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        state.returnFromBackground()
        if let window = NSApp.windows.first(where: { Self.isMain($0) && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            _ = HairWordArt.shared      // start baking while the window opens
            _ = HairWordArt.finished
            reopenWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
