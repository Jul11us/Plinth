import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Vision

struct BarberView: View {
    @Environment(AppState.self) private var state
    @State private var toast: String?
    @State private var share = ShareDelegate()
    @State private var exportSaved = false          // all saved styles on one sheet, instead of the selected one
    @State private var hairFormShown = false

    private var styles: [Hairstyle] {
        let saved = savedStyles
        return saved.isEmpty ? state.pool : saved
    }

    private var savedStyles: [Hairstyle] { state.savedStyles }
    private var canCombine: Bool { savedStyles.count >= 2 }
    private var combining: Bool { exportSaved && canCombine }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            ScrollView {
                onScreen
                    .shadow(color: .black.opacity(0.06), radius: 14, y: 4)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)   // room for the shadow inside the scroll view
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: 840)

            actions.frame(width: 256)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) {
            if let toast { Toast(text: toast) }
        }
        .onAppear { share.onResult = { flash($0) } }
    }

    private var export: BarberExport { BarberExport(state: state) }

    private func card(phone: Bool = false, wide: Bool = false, imageHeight: CGFloat = 280) -> BarberCard {
        export.card(for: state.selectedStyle, phone: phone, wide: wide, imageHeight: imageHeight)
    }

    private func sheet(wide: Bool = false) -> BarberSheet {
        BarberSheet(styles: savedStyles, goal: savedStyles.first.flatMap(export.goal(for:)), currentHair: state.hairPreferences.currentHair, dye: export.dyeRows, wide: wide)
    }

    /// The tall version that prints; the phone export is its bigger-type sibling.
    @ViewBuilder private var preview: some View {
        if combining { sheet() } else { card() }
    }

    /// Laid out landscape so the whole card fits the window without scrolling.
    @ViewBuilder private var onScreen: some View {
        if combining { sheet(wide: true) } else { card(wide: true) }
    }

    private static let thumbnail = CGSize(width: 40, height: 50)
    private static let thumbnailsPerRow = 5

    /// Hidden when there is nothing to choose between.
    @ViewBuilder private var picker: some View {
        if styles.count > 1 || styles.first?.id != state.selectedStyleID {
            let rows = min(3, (styles.count + Self.thumbnailsPerRow - 1) / Self.thumbnailsPerRow)
            VStack(alignment: .leading, spacing: 8) {
                Text(state.savedStyleIDs.isEmpty ? "推荐的发型" : "收藏的发型")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.fhSecondary)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.thumbnail.width), spacing: 9), count: Self.thumbnailsPerRow),
                              alignment: .leading, spacing: 9) {
                        ForEach(styles) { s in thumbnail(s) }
                    }
                    .padding(3)         // room for the selection ring
                }
                .scrollIndicators(.never)
                .frame(height: CGFloat(rows) * (Self.thumbnail.height + 9) - 9 + 6)
                if state.savedStyleIDs.isEmpty {
                    Text("在发型页点书签可以收藏几款，到店再定。")
                        .font(.system(size: 11)).foregroundStyle(Color.fhTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func thumbnail(_ s: Hairstyle) -> some View {
        let on = !combining && s.id == state.selectedStyleID
        return Button {
            state.selectedStyleID = s.id        // no animation: cross-fading two cards doubles up all the text
            exportSaved = false
        } label: {
            StyleImage(style: s)
                .frame(width: Self.thumbnail.width, height: Self.thumbnail.height)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.ink, lineWidth: 1.5)
                        .padding(-3)
                        .opacity(on ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(s.name)
        .accessibilityLabel(s.name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private static let salonSteps = ["先说卡片上那一句话", "给理发师看照片，提一下「别这样剪」", "剪到一半，再对一下长度"]

    private var actions: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 20) {
            Text("把这张卡片给理发师看，就够了。").font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            picker
            VStack(alignment: .leading, spacing: 8) {
                if canCombine {
                    Picker("导出内容", selection: $exportSaved) {
                        Text("这一款").tag(false)
                        Text("收藏的 \(savedStyles.count) 款").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .padding(.bottom, 2)
                }
                CapsuleButton(title: "隔空投送到 iPhone", systemImage: "iphone", expand: true) { airDrop() }
                HStack(spacing: 8) {
                    ExportButton(title: "存图片", systemImage: "arrow.down.to.line", help: "存成适合手机看的图片") { saveImage() }
                    ExportButton(title: "复制文字", systemImage: "doc.on.doc", help: "复制成文字，发微信") { copyText() }
                    ExportButton(title: "打印", systemImage: "printer", help: "打印这张卡片") { printCard() }
                }
                Text("发到手机和存图时是竖版，一屏看完。")
                    .font(.system(size: 11)).foregroundStyle(Color.fhTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("到店时").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.fhSecondary)
                ForEach(Array(Self.salonSteps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.fhSecondary)
                        Text(step).font(.fhSmall).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if state.hairPreferences.currentHair == nil {
                Button { hairFormShown = true } label: {
                    Label("填一下现在的头发，卡片上会多一行", systemImage: "plus.circle")
                        .font(.fhSmall).foregroundStyle(Color.fhSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $hairFormShown, arrowEdge: .leading) { HairPreferencesView(preferences: $state.hairPreferences) }
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: Export

    /// The version that goes on a phone.
    @MainActor private func renderForPhone() -> Data? {
        guard combining else { return export.phonePNG(for: state.selectedStyle) }
        let r = ImageRenderer(content: sheet().frame(width: BarberCard.phoneSize.width)
            .frame(minHeight: BarberCard.phoneSize.height, alignment: .top).background(Color.white))
        r.scale = 3
        return BarberExport.png(r.cgImage)
    }

    @MainActor private func renderForPrint() -> Data? {
        let r = ImageRenderer(content: preview.frame(width: 440).padding(20).background(Theme.stone))
        r.scale = 2
        return BarberExport.png(r.cgImage)
    }

    private var exportName: String { combining ? "理发师卡片-收藏的\(savedStyles.count)款" : "理发师卡片-\(state.selectedStyle.name)" }

    private func airDrop() {
        guard let url = renderForPhone().flatMap({ export.temporaryFile($0, name: exportName) }) else { return }
        if let problem = export.airDrop(url, delegate: share) { flash(problem) }
    }

    private func saveImage() {
        guard let data = renderForPhone() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(exportName).png"
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url); flash("已保存") } catch { flash("保存失败：\(error.localizedDescription)") }
        }
    }

    private func copyText() {
        export.copyText(for: combining ? savedStyles : [state.selectedStyle], combined: combining)
        flash("已复制，可以直接粘贴到微信")
    }

    private func printCard() {
        guard let data = renderForPrint(), let img = NSImage(data: data) else { return }
        let view = NSImageView(frame: NSRect(origin: .zero, size: NSSize(width: img.size.width / 2, height: img.size.height / 2)))
        view.image = img
        view.imageScaling = .scaleProportionallyUpOrDown
        let op = NSPrintOperation(view: view)
        // The card is taller than a Letter page's printable area; scale it to fit one page, centred.
        op.printInfo.horizontalPagination = .fit
        op.printInfo.verticalPagination = .fit
        op.printInfo.isHorizontallyCentered = true
        op.printInfo.isVerticallyCentered = true
        op.run()
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }
}

/// What a card says for this person, shared by the card page and the menu-bar panel.
@MainActor
struct BarberExport {
    let state: AppState

    var dyeRows: [(String, String)] { ColourAdvisor.cardRows(shade: state.hairShade, profile: state.cardContext.profile) }

    func goal(for style: Hairstyle) -> String? { state.cardContext.shape?.barberGoal(for: style.gender) }

    private func hairNotes(for style: Hairstyle) -> [String] {
        var notes = style.hairProfile.notes(for: state.hairPreferences)
        if let minutes = state.hairPreferences.budget.minutes { notes.insert("每天打理希望控制在 \(minutes) 分钟以内。", at: 0) }
        return notes
    }

    private var leaning: String? {
        guard !state.usesMixedRecommendations, state.shape == state.classification?.primary, let s = state.classification?.secondary else { return nil }
        return s.shape.leaning
    }

    func card(for style: Hairstyle, phone: Bool = false, wide: Bool = false, imageHeight: CGFloat = 280) -> BarberCard {
        BarberCard(style: style, shape: state.shape, leaning: leaning, hasResult: state.hasResult,
                   dye: dyeRows, goal: goal(for: style), currentHair: state.hairPreferences.currentHair,
                   hairNotes: hairNotes(for: style), phone: phone, wide: wide, imageHeight: imageHeight)
    }

    static func png(_ image: CGImage?) -> Data? {
        image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    /// Bigger type on one screen, shrinking the picture until it fits.
    func phonePNG(for style: Hairstyle) -> Data? {
        var image: CGImage?
        for height: CGFloat in [300, 250, 200, 160] {
            let r = ImageRenderer(content: card(for: style, phone: true, imageHeight: height).frame(width: BarberCard.phoneSize.width)
                .frame(minHeight: BarberCard.phoneSize.height, alignment: .top).background(Color.white))
            r.scale = 3
            image = r.cgImage
            if let image, CGFloat(image.height) <= BarberCard.phoneSize.height * 3 { break }
        }
        return Self.png(image)
    }

    func temporaryFile(_ data: Data, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        return (try? data.write(to: url)) == nil ? nil : url
    }

    /// Returns what went wrong, if anything.
    func airDrop(_ url: URL, delegate: ShareDelegate) -> String? {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [url]) else {
            return "这台 Mac 现在不能隔空投送"
        }
        service.delegate = delegate
        service.perform(withItems: [url])
        return nil
    }

    func text(for styles: [Hairstyle], combined: Bool) -> String {
        var blocks: [String] = []
        if combined { blocks.append("到店再定，这几款都可以：") }
        for s in styles {
            var lines = ["【\(s.name)】给理发师", "一句话：\(s.say)"]
            if let goal = goal(for: s) { lines.append("想要的效果：\(goal)") }
            if let hair = state.hairPreferences.currentHair { lines.append("现在的头发：\(hair)") }
            for (k, v) in zip(Hairstyle.specLabels, s.specs) { lines.append("\(k)：\(v)") }
            for (k, v) in dyeRows { lines.append("\(k)：\(v)") }
            lines.append("别这样剪：" + s.avoid.joined(separator: "；"))
            blocks.append(lines.joined(separator: "\n"))
        }
        if !combined, let style = styles.first { blocks.append(contentsOf: hairNotes(for: style)) }
        if state.hasResult { blocks.append(state.faceSummary) }
        return blocks.joined(separator: "\n\n")
    }

    func copyText(for styles: [Hairstyle], combined: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: styles, combined: combined), forType: .string)
    }
}

/// Reports how AirDrop went, so the screen can say "已发送" instead of staying silent.
@MainActor
final class ShareDelegate: NSObject, NSSharingServiceDelegate {
    var onResult: ((String) -> Void)?
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor in self.onResult?("已隔空投送") }
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let cancelled = (error as NSError).code == NSUserCancelledError
        Task { @MainActor in if !cancelled { self.onResult?("隔空投送没有成功") } }
    }
}

/// The part of a 4:5 bust picture from just above the hair to just below the chin, as fractions of its height.
enum BustBand {
    private static var cache: [String: CGRect] = [:]

    @MainActor static func of(_ imageName: String) -> CGRect {
        if let known = cache[imageName] { return known }
        var band = CGRect(x: 0, y: 0.085, width: 1, height: 0.565)
        if let image = Res.image(imageName).cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let request = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            if let face = request.results?.first?.boundingBox {
                let top = max(0, 1 - face.maxY - face.height * 0.72)
                let bottom = min(1, 1 - face.minY + face.height * 0.2)
                band = CGRect(x: 0, y: top, width: 1, height: bottom - top)
            }
        }
        cache[imageName] = band
        return band
    }

    private static var extents: [String: CGRect] = [:]

    /// The window of a 4:5 bust picture that shows all of the hair at head height, with the given width-to-height
    /// ratio, as fractions of the picture. Short hair stops at `tightest` so a buzz cut isn't blown up to fill it.
    @MainActor static func hairWindow(_ imageName: String, aspect: CGFloat, tightest: CGFloat = 0.58) -> CGRect {
        let extent = extents[imageName] ?? {
            let found = Res.image(imageName).cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(hairExtent)
            let measured = found ?? CGRect(x: 0.2, y: 0.05, width: 0.6, height: 0.5)
            extents[imageName] = measured
            return measured
        }()
        let shape = 0.8 / aspect                        // window height for a window one picture-width wide
        let width = min(1 / shape, 1, max(tightest, extent.width * 1.16))
        let height = width * shape
        return CGRect(x: min(1 - width, max(0, extent.midX - width / 2)),
                      y: min(1 - height, max(0, extent.minY - 0.035)),
                      width: width, height: height)
    }

    /// Where anything differs from the wall in the top of the picture, above where shoulders start.
    private static func hairExtent(_ image: CGImage) -> CGRect? {
        let w = 64, h = 80
        var gray = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = gray.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            c.interpolationQuality = .medium
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let wall = (Int(gray[w + 1]) + Int(gray[2 * w - 2])) / 2       // the top corners are always wall
        func solid(_ x: Int, _ y: Int) -> Bool {
            abs(Int(gray[y * w + x]) - wall) > 9 && abs(Int(gray[y * w + x + 1]) - wall) > 9
        }
        guard let top = (0..<h).first(where: { y in (0..<(w - 1)).contains { solid($0, y) } }) else { return nil }
        var left = w, right = 0
        for y in top..<min(h, top + h * 42 / 100) {
            guard let l = (0..<(w - 1)).first(where: { solid($0, y) }),
                  let r = (0..<(w - 1)).last(where: { solid($0, y) }) else { continue }
            left = min(left, l); right = max(right, r + 1)
        }
        guard right > left else { return nil }
        return CGRect(x: CGFloat(left) / CGFloat(w), y: CGFloat(top) / CGFloat(h),
                      width: CGFloat(right - left + 1) / CGFloat(w), height: 0.42)
    }
}

/// The card itself. The app shows it at desktop size; `phone` makes the bigger-type version that gets exported.
struct BarberCard: View {
    /// iPhone screen in points: the exported card aims to fit one of these.
    static let phoneSize = CGSize(width: 430, height: 932)

    let style: Hairstyle
    let shape: FaceShape
    var leaning: String?
    var hasResult = true
    /// 发色 / 打底 rows, when the user picked a colour on the try-on page.
    var dye: [(String, String)] = []
    var goal: String? = nil
    var currentHair: String? = nil
    var hairNotes: [String] = []
    var phone = false
    /// Landscape, for the window. Same content as the tall card that gets exported.
    var wide = false
    var imageHeight: CGFloat = 280

    private static let keyRows: Set<String> = ["长度", "两侧 / 后颈"]
    private func size(_ points: CGFloat) -> CGFloat { phone ? points * 1.22 : points }

    private var rows: [(String, String)] {
        (currentHair.map { [("现在的头发", $0)] } ?? []) + Array(zip(Hairstyle.specLabels, style.specs)) + dye
    }

    var body: some View {
        Group { if wide { wideLayout } else { tallLayout } }
            .foregroundStyle(Theme.ink)
            .padding(wide ? 30 : (phone ? 24 : 22))
            .background(Color.white, in: RoundedRectangle(cornerRadius: phone ? 0 : 16, style: .continuous))
    }

    private var tallLayout: some View {
        VStack(alignment: .leading, spacing: phone ? 14 : 16) {
            masthead
            title
            pictures
            quote
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, pair in rowView(pair, divided: i > 0) }
            }
            avoidList
            notes
        }
    }

    private var wideLayout: some View {
        let key = rows.filter { Self.keyRows.contains($0.0) }, rest = rows.filter { !Self.keyRows.contains($0.0) }
        return VStack(alignment: .leading, spacing: 20) {
            masthead
            title
            quote
            HStack(alignment: .top, spacing: 24) {
                pictures.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(key.enumerated()), id: \.offset) { _, pair in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pair.0).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.fhSecondary)
                            Text(pair.1).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    avoidList
                }
                .frame(width: 200, alignment: .leading)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: 0) {
                ForEach(Array(rest.enumerated()), id: \.offset) { _, pair in rowView(pair, divided: true) }
            }
            notes
        }
    }

    private var masthead: some View {
        HStack {
            Text("Plinth · 给理发师看").font(.system(size: size(11), weight: .medium))
            Spacer()
            Text("\(style.gender == .female ? "女" : "男") · \(style.length.label)").font(.system(size: size(11)))
        }
        .foregroundStyle(Color.fhSecondary)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(style.name).font(.system(size: wide ? 30 : size(26), weight: .semibold))
            if let goal {
                Text(goal).font(.system(size: wide ? 15 : size(14))).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var pictures: some View {
        if style.hasAllViews {
            BustViews(style: style, labelSize: size(11))
        } else {
            BustPicture(style: style).frame(height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var quote: some View {
        Text("“\(style.say)”")
            .font(.system(size: wide ? 19 : size(17), weight: .medium))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(wide ? 16 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func rowView(_ pair: (String, String), divided: Bool) -> some View {
        let key = Self.keyRows.contains(pair.0)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(pair.0).font(.system(size: size(12), weight: key ? .semibold : .regular))
                .foregroundStyle(key ? Theme.ink : Color.fhSecondary)
                .frame(width: size(wide ? 66 : 76), alignment: .leading)
            Text(pair.1).font(.system(size: wide ? 15 : size(key ? 16 : 14), weight: key ? .semibold : .regular))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, wide ? 10 : 7)
        .overlay(alignment: .top) { if divided { Rectangle().fill(Color(hex: 0xEEEDEA)).frame(height: 1) } }
    }

    private var avoidList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("别这样剪").font(.system(size: size(12), weight: .semibold))
            ForEach(style.avoid, id: \.self) { a in
                Label(a, systemImage: "xmark").font(.system(size: size(14))).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var notes: some View {
        if !hairNotes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(hairNotes, id: \.self) { note in
                    Text(note).font(.system(size: size(12))).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One of the small secondary ways to take the card out of the app.
private struct ExportButton: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 14))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.white.opacity(hovered ? 0.95 : 0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovered)
    }
}

/// Several saved styles on one sheet, for "I'll decide at the salon".
struct BarberSheet: View {
    static let limit = 6

    let styles: [Hairstyle]
    var goal: String? = nil
    var currentHair: String? = nil
    var dye: [(String, String)] = []
    /// Two columns, for the window.
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Plinth · 给理发师看").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("到店再定，这 \(min(styles.count, Self.limit)) 款都可以").font(.system(size: 13))
            }
            .foregroundStyle(Color.fhSecondary)

            if goal != nil || currentHair != nil || !dye.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if let goal { Text(goal).font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true) }
                    if let currentHair { Text("现在的头发：\(currentHair)").font(.system(size: 13)).foregroundStyle(Color.fhSecondary) }
                    ForEach(Array(dye.enumerated()), id: \.offset) { _, row in
                        Text("\(row.0)：\(row.1)").font(.system(size: 13)).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if wide {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 24, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: 20) {
                    ForEach(Array(styles.prefix(Self.limit).enumerated()), id: \.element.id) { i, style in entry(i, style) }
                }
            } else {
                ForEach(Array(styles.prefix(Self.limit).enumerated()), id: \.element.id) { i, style in
                    entry(i, style)
                    if i < min(styles.count, Self.limit) - 1 { Rectangle().fill(Color(hex: 0xEEEDEA)).frame(height: 1) }
                }
            }

            if styles.count > Self.limit {
                Text("还收藏了 \(styles.count - Self.limit) 款，这里放不下。").font(.system(size: 12)).foregroundStyle(Color.fhTertiary)
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(22)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func entry(_ i: Int, _ style: Hairstyle) -> some View {
        HStack(alignment: .top, spacing: 14) {
            BustPicture(style: style)
                .frame(width: 104, height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("\(i + 1). \(style.name)").font(.system(size: 18, weight: .semibold))
                Text(style.say).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                spec("长度", style.specs[0])
                spec("两侧", style.specs[3])
            }
            Spacer(minLength: 0)
        }
    }

    private func spec(_ label: String, _ value: String) -> some View {
        (Text(label + "  ").foregroundStyle(Color.fhSecondary) + Text(value).fontWeight(.semibold))
            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }
}

/// Front, side and back together, each cropped to head and neck: what a hairdresser needs to see the shape.
struct BustViews: View {
    let style: Hairstyle
    var labelSize: CGFloat = 11

    private static let tileAspect: CGFloat = 0.74

    var body: some View {
        HStack(spacing: 8) {
            tile(style.imageName, "正面")
            tile(style.sideImageName, "侧面")
            tile(style.backImageName, "背面")
        }
    }

    private func tile(_ name: String, _ label: String) -> some View {
        Color(hex: 0xCBC7C4)            // the wall colour of the bust pictures
            .aspectRatio(Self.tileAspect, contentMode: .fit)
            .overlay {
                GeometryReader { g in
                    let window = BustBand.hairWindow(name, aspect: Self.tileAspect)
                    let height = g.size.height / window.height
                    let width = height * 0.8
                    Image(nsImage: Res.image(name))
                        .resizable()
                        .frame(width: width, height: height)
                        .position(x: width / 2 - window.minX * width, y: height / 2 - window.minY * height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text(label).font(.system(size: labelSize, weight: .medium)).foregroundStyle(Color.fhSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.white.opacity(0.75), in: Capsule())
                    .padding(5)
            }
    }
}

/// A bust cropped from just above the hair to just below the chin, however tightly the picture was framed.
private struct BustPicture: View {
    let style: Hairstyle

    var body: some View {
        if Res.hasImage(style.imageName) {
            GeometryReader { g in
                let band = BustBand.of(style.imageName)
                let full = g.size.width * 1.25
                let scale = min(1, g.size.height / (band.height * full))
                let offset = (g.size.height - band.height * full * scale) / 2 - band.minY * full * scale
                Image(nsImage: Res.image(style.imageName))
                    .resizable()
                    .frame(width: g.size.width * scale, height: full * scale)
                    .frame(maxWidth: .infinity)
                    .offset(y: offset)
            }
            .background(Color(hex: 0xCBC7C4))     // the wall colour of the bust pictures
        } else {
            StyleImage(style: style)
        }
    }
}
