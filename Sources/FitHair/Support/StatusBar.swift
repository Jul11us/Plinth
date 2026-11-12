import SwiftUI
import AppKit
import UserNotifications

struct SystemTrimReminder: TrimReminding {
    private static let identifier = "plinth.trim"

    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func schedule(at date: Date, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: Self.identifier, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }
}

/// The icon in the menu bar and the small panel it opens. Photos dropped on the icon go straight to analysis.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate, NSWindowDelegate, NSDraggingDestination {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let state: AppState
    private let showApp: () -> Void

    init(state: AppState, showApp: @escaping () -> Void) {
        self.state = state
        self.showApp = showApp
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        guard let button = item.button else { return }
        button.image = Self.icon
        button.toolTip = "Plinth"
        button.target = self
        button.action = #selector(toggle)
        button.window?.registerForDraggedTypes([.fileURL])
        button.window?.delegate = self
    }

    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        let panel = StatusPanel(close: { [weak self] in self?.popover.performClose(nil) }, showApp: { [weak self] in
            self?.popover.performClose(nil)
            self?.showApp()
        })
        let host = NSHostingController(rootView: panel.environment(state))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// The panel is only built while it's open, so a resident app stays light.
    func popoverDidClose(_ notification: Notification) { popover.contentViewController = nil }

    // MARK: Dropping a photo on the icon

    private func photoURL(in sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: ["public.image"]]
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { photoURL(in: sender) == nil ? [] : .copy }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = photoURL(in: sender) else { return false }
        showApp()
        state.load(url: url)
        return true
    }

    // MARK: Icon

    /// The opening's P with its lock of hair, in one colour so it follows the menu bar's appearance.
    private static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let font = NSFont(name: HairWord.fontName, size: 18) ?? .systemFont(ofSize: 15)
            NSAttributedString(string: "P", attributes: [.font: font, .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 6, y: -3))
            let lock = NSBezierPath()
            lock.move(to: NSPoint(x: 13, y: 13.2))
            lock.curve(to: NSPoint(x: 3.2, y: 16.8), controlPoint1: NSPoint(x: 8, y: 13.2), controlPoint2: NSPoint(x: 1.8, y: 13.2))
            lock.lineWidth = 1.1
            lock.lineCapStyle = .round
            lock.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// What the menu-bar icon opens: the current style, when it's next due, and the card on its way to the phone.
struct StatusPanel: View {
    @Environment(AppState.self) private var state
    let close: () -> Void
    let showApp: () -> Void
    @State private var note: String?
    @State private var share = ShareDelegate()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let style = state.currentStyle {
                header(style)
                divider
                trim(style)
                divider
                send(style)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("还没有收藏发型").font(.system(size: 15, weight: .semibold))
                    Text("在发型库点书签收藏一款，这里就能看修剪时间，随时发出卡片。")
                        .font(.fhSmall).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let note {
                Text(note).font(.fhSmall).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
            }
            divider
            HStack {
                Button("打开 Plinth") { showApp() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.foregroundStyle(Color.fhSecondary)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
        }
        .foregroundStyle(Theme.ink)
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .preferredColorScheme(.light)
        .onAppear { share.onResult = { note = $0 } }
    }

    private var divider: some View { Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1) }

    private func header(_ style: Hairstyle) -> some View {
        @Bindable var state = state
        return HStack(spacing: 12) {
            StyleImage(style: style)
                .frame(width: 44, height: 55)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("当前发型").font(.system(size: 11)).foregroundStyle(Color.fhSecondary)
                if state.savedStyles.count > 1 {
                    Picker("当前发型", selection: Binding(get: { style.id }, set: { state.currentStyleID = $0 })) {
                        ForEach(state.savedStyles) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                } else {
                    Text(style.name).font(.system(size: 15, weight: .semibold))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func trim(_ style: Hairstyle) -> some View {
        let status = state.lastCut.flatMap { cut in style.trimCycle?.status(lastCut: cut) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(status?.since ?? "还没有记录上次剪发").font(.system(size: 14, weight: .medium))
            Text(status?.advice ?? "这款建议 \(style.cycle)修剪一次")
                .font(.fhSmall)
                .foregroundStyle(status?.stage == .overdue ? Theme.ink : Color.fhSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                QuietButton(title: "今天剪了", systemImage: "scissors") { state.markCutToday() }
                if state.canUndoCut {
                    Button("撤销") { state.undoCut() }.buttonStyle(.plain).font(.fhSmall).foregroundStyle(Color.fhSecondary)
                }
                Spacer(minLength: 0)
            }
            Toggle("到时间提醒我", isOn: Binding(get: { state.remindersOn }, set: { on in
                Task {
                    if !(await state.setReminders(on)) { note = "通知没有打开，可以到系统设置 › 通知里允许 Plinth。" }
                }
            }))
            .toggleStyle(.checkbox)
            .font(.fhSmall)
        }
    }

    private func send(_ style: Hairstyle) -> some View {
        VStack(spacing: 8) {
            CapsuleButton(title: "隔空投送到 iPhone", systemImage: "iphone", expand: true) { airDrop(style) }
            QuietButton(title: "复制文字，发微信", systemImage: "doc.on.doc", expand: true) {
                BarberExport(state: state).copyText(for: [style], combined: false)
                note = "已复制，可以直接粘贴到微信"
            }
        }
    }

    private func airDrop(_ style: Hairstyle) {
        let export = BarberExport(state: state)
        guard let url = export.phonePNG(for: style).flatMap({ export.temporaryFile($0, name: "理发师卡片-\(style.name)") }) else {
            note = "卡片没有生成成功"
            return
        }
        if let problem = export.airDrop(url, delegate: share) { note = problem }
    }
}
