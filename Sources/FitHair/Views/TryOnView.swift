import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Lays the chosen style on the user's photo, on this Mac. Hold the picture to see the original.
struct TryOnView: View {
    @Environment(AppState.self) private var state
    @State private var family = HairTryOn.Shade.Family.natural
    @State private var renderer = TryOnRenderer(showsDrafts: !HairRepaint.isInstalled)
    @State private var installer = RepaintModelInstaller.shared
    @State private var showOriginal = false
    @State private var toast: String?

    private var style: Hairstyle { state.selectedStyle }
    private var shade: HairTryOn.Shade { state.hairShade }
    private var key: TryOnRenderer.Key {
        .init(photoID: state.photoID, styleID: style.id, shadeID: shade.id)
    }
    private var output: HairTryOn.Output? { renderer.output(for: key) }
    private var failure: String? { renderer.failure(for: key) }
    /// With the image model installed only its picture is shown. Until it is ready the last picture of this photo
    /// stays up, or the photo itself, under a note of what is being done.
    private var waiting: CGImage? {
        guard HairRepaint.isInstalled, output == nil else { return nil }
        return renderer.standIn(for: key)?.image ?? renderer.framedPhoto(for: key)
    }

    /// Only styles with a bust picture can be tried on: saved ones first, then the best for this face.
    private var choices: [Hairstyle] {
        let candidates = Hairstyle.pool(for: state.recommendationScores, gender: state.gender, length: nil, preferences: state.hairPreferences).filter { Res.hasImage($0.imageName) }
        return candidates.filter { state.savedStyleIDs.contains($0.id) } + candidates.filter { !state.savedStyleIDs.contains($0.id) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            picture
                .aspectRatio(0.8, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            panel
                .padding(.vertical, 4)
                .frame(width: 340)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 48)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .task(id: key) { await render() }
        // The model arrived while this page was open: from here on the pictures are the realistic ones.
        .onChange(of: installer.phase == .installed) { _, there in
            guard there else { return }
            renderer = TryOnRenderer(showsDrafts: false)
            Task { await render() }
        }
        .overlay(alignment: .bottom) { if let toast { Toast(text: toast) } }
        .onAppear { family = shade.family }
        // The model is left loaded: it gives its memory back by itself a few minutes after it was last used.
        .onDisappear { renderer.cancel() }
    }

    // MARK: Picture

    @ViewBuilder private var picture: some View {
        ZStack {
            Theme.paper
            if !style.hairProfile.supportsTryOn {
                VStack(spacing: 16) {
                    StyleImage(style: style)
                        .aspectRatio(4.0 / 5.0, contentMode: .fit)
                        .frame(maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("这款暂只提供发型示意").font(.fhHeading)
                    Text("可以直接做理发师卡片，或在右边换一款试戴。")
                        .font(.fhSmall).foregroundStyle(Color.fhSecondary).multilineTextAlignment(.center)
                }
                .padding(20)
            } else if state.measurement == nil {
                noPhoto
            } else if failure == nil, let waiting {
                // Out of focus: what is up is the last picture or the photo, not the one being made.
                Image(decorative: waiting, scale: 1).resizable()
                    .blur(radius: 12, opaque: true)
                    .accessibilityLabel("正在生成\(style.name)的试戴效果")
                WorkingVeil(note: renderer.progress(for: key) ?? "正在摆好\(style.name)…")
                    .transition(.opacity)
            } else if failure == nil, let output = output ?? renderer.standIn(for: key) {
                Image(decorative: showOriginal ? output.original : output.image, scale: 1).resizable()
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in showOriginal = true }
                        .onEnded { _ in showOriginal = false })
                    .accessibilityLabel(showOriginal ? "你的原图" : "试戴\(style.name)的效果")
                if renderer.refineFailed(key) {
                    Text("写实效果没画出来，这是示意图")
                    .font(.fhSmall).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(.black.opacity(0.5), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 14)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                Text(showOriginal ? "原图" : "按住看原图")
                    .font(.fhSmall).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(.black.opacity(0.45), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 14)
                    .allowsHitTesting(false)
            } else if let failure {
                VStack(spacing: 10) {
                    Image(systemName: "scissors").font(.system(size: 26, weight: .light)).foregroundStyle(Color.fhTertiary)
                    Text(failure).font(.fhBody).foregroundStyle(Color.fhSecondary).multilineTextAlignment(.center).frame(maxWidth: 280)
                    Text("右边换一款试试").font(.fhSmall).foregroundStyle(Color.fhTertiary)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("正在生成\(style.name)的试戴效果…").font(.fhSmall).foregroundStyle(Color.fhSecondary)
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: waiting == nil)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }

    private var noPhoto: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.rectangle").font(.system(size: 30, weight: .light)).foregroundStyle(Color.fhTertiary)
            Text("先要一张你的正脸照片").font(.fhHeading)
            Text("照片只在这台 Mac 上处理").font(.fhSmall).foregroundStyle(Color.fhSecondary)
            HStack(spacing: 10) {
                CapsuleButton(title: "拍一张") { state.go(.capture) }
                QuietButton(title: "选一张照片…") { state.pickPhoto() }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Panel

    /// The buttons stay on screen: the choices scroll only when the window is too short to show everything.
    private var panel: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 16) { panelContent; panelActions }
                .padding(20)
                .panelCard()
            VStack(spacing: 0) {
                ScrollView { panelContent.padding(20) }
                    .scrollIndicators(.automatic)
                panelActions.padding(.horizontal, 20).padding(.vertical, 14)
            }
            .panelCard()
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(style.name).font(.fhHeading)
                Text("\(style.length.label) · \(state.suitabilityLabel) \(state.suitability(of: style))").font(.fhSmall).foregroundStyle(Color.fhSecondary)
            }

            // First thing in the panel: at the bottom it would be below the fold on a short window.
            modelOffer

            colours
            if !style.hairProfile.supportsTryOn {
                Text("这款暂不支持照片试戴，发色选择会记录到理发师卡片。")
                    .font(.fhSmall).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("换一款").font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(choices) { thumbnail($0) }
                }
            }

            Text(HairRepaint.isInstalled
                 ? "由这台 Mac 上的图像模型把这款发型画到你的照片上，要几秒钟。是预览，不是成片；原来被头发挡住的地方是推测的。照片不会上传。"
                 : "用发型的轮廓和纹理贴到你的照片上，是示意，不是成片。全部在这台 Mac 上完成，照片不会上传。")
                .font(.fhSmall).foregroundStyle(Color.fhTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The realistic try-on needs an image model that is not in the app: about 2 GB, fetched once, when asked for.
    @ViewBuilder private var modelOffer: some View {
        switch installer.phase {
        case .installed, .unavailable:
            EmptyView()
        case .offered:
            offerCard {
                Text("想看更真实的效果？").font(.system(size: 13, weight: .semibold))
                Text("下载一个图像模型（约 2 GB，只下一次），之后这台 Mac 会把头发画成真实发丝。模型和照片都留在本机。")
                    .font(.fhSmall).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
                QuietButton(title: "下载写实效果", systemImage: "arrow.down.circle", expand: true) { installer.start() }
            }
        case .paused:
            offerCard {
                Text("下载已暂停").font(.system(size: 13, weight: .semibold))
                Text("已经下好的部分留着，继续时接着下。")
                    .font(.fhSmall).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
                QuietButton(title: "继续下载", systemImage: "arrow.down.circle", expand: true) { installer.start() }
            }
        case .downloading(let done, let total):
            offerCard {
                Text("正在下载写实效果…").font(.system(size: 13, weight: .semibold))
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text("\(Self.megabytes(done)) / \(Self.megabytes(total))　可以先继续试戴，下载不会断")
                        .font(.fhSmall).foregroundStyle(Color.fhSecondary).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
                QuietButton(title: "暂停", expand: true) { installer.cancel() }
            }
        case .unpacking:
            offerCard {
                Text("正在解压和校验…").font(.system(size: 13, weight: .semibold))
                ProgressView().progressViewStyle(.linear)
                Text("马上就好，大约十几秒。").font(.fhSmall).foregroundStyle(Color.fhSecondary)
            }
        case .failed(let why):
            offerCard {
                Text("写实效果没下载成功").font(.system(size: 13, weight: .semibold))
                Text(why).font(.fhSmall).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
                QuietButton(title: "再试一次", systemImage: "arrow.clockwise", expand: true) { installer.start() }
            }
        }
    }

    private func offerCard(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var panelActions: some View {
        let saved = state.savedStyleIDs.contains(style.id)
        return VStack(alignment: .leading, spacing: 8) {
            // Says what it does: making the card also keeps the style in the saved list.
            CapsuleButton(title: saved ? "就剪这个，做卡片" : "收藏，做理发师卡片", expand: true) {
                if !saved { state.toggleSaved(style.id) }
                state.go(.barber)
            }
            // Only what is on screen as the finished picture can be saved.
            let ready = output != nil && !renderer.isRefining(key)
            QuietButton(title: "存为图片…", systemImage: "arrow.down.to.line", expand: true) { save() }
                .disabled(!ready)
                .opacity(ready ? 1 : 0.45)
        }
    }

    private var colours: some View {
        let suggested = ColourAdvisor.suggestions(for: state.colourProfile)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("发色").font(.system(size: 13, weight: .semibold))
                Spacer()
                swatchLabel
            }

            if !suggested.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("适合你的肤色（光线会影响判断，仅供参考）").font(.system(size: 11)).foregroundStyle(Color.fhSecondary)
                    HStack(spacing: 14) { ForEach(suggested) { swatch($0) } }
                }
            } else if state.measurement != nil {
                Text("这张照片看不出肤色冷暖，下面的颜色都可以试。").font(.system(size: 11)).foregroundStyle(Color.fhTertiary)
            }

            Picker("色系", selection: $family) {
                ForEach(HairTryOn.Shade.Family.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack(spacing: 14) {
                ForEach(HairTryOn.Shade.all.filter { $0.family == family }) { swatch($0) }
            }

            if let note = ColourAdvisor.baseNote(for: shade, profile: state.colourProfile) {
                Text(note + "。").font(.fhSmall).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The chosen colour in words, next to the section title.
    private var swatchLabel: some View {
        Text([shade.name, ColourAdvisor.description(of: shade)].compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 11)).foregroundStyle(Color.fhSecondary)
    }

    private func swatch(_ s: HairTryOn.Shade) -> some View {
        let on = s == shade
        return Button { state.hairShade = s; family = s.family } label: {
            VStack(spacing: 4) {
                ZStack {
                    if let hex = s.hex {
                        Circle().fill(Color(hex: hex))
                    } else {
                        Circle().fill(Theme.paper)
                        Image(systemName: "wand.and.stars").font(.system(size: 11)).foregroundStyle(Color.fhSecondary)
                    }
                }
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(on ? Theme.ink : Color.black.opacity(0.08), lineWidth: on ? 2 : 1))
                Text(s.name).font(.system(size: 10, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.ink : Color.fhSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("发色：\(s.name)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func thumbnail(_ s: Hairstyle) -> some View {
        let on = s.id == style.id
        let tile = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button { state.selectedStyleID = s.id } label: {
            StyleImage(style: s)
                .aspectRatio(4 / 5, contentMode: .fit)
                .clipShape(tile)
                .overlay(tile.strokeBorder(on ? Theme.ink : Color.black.opacity(0.06), lineWidth: on ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(s.name)
        .accessibilityLabel("试戴\(s.name)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Work

    private func render() async {
        showOriginal = false
        guard style.hairProfile.supportsTryOn, let photo = state.photo, let face = state.measurement else { renderer.cancel(); return }
        let key = self.key, style = self.style, shade = self.shade
        let realistic = HairRepaint.isInstalled
        await renderer.render(key) {
            try await Task.detached(priority: .userInitiated) {
                try Self.make(photo: photo, face: face, style: style, shade: shade, forRepaint: realistic)
            }.value
        }
        guard realistic else { return }
        // Flicking through styles shouldn't start seconds of work for each one passed.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let renderer = self.renderer
        await renderer.refine(key) { draft in
            let image = try await HairRepaint.shared.render(draft, style: style.tryOnPrompt, colour: shade.promptName,
                                                                      scene: "\(key.photoID)-\(key.styleID)") { step in
                let note = switch step {
                case .loading: "正在准备…"
                case .clearing: "正在清理原来的头发…"
                case .drawing: "正在画出发丝…"
                case .finishing: "正在精修细节…"
                }
                Task { @MainActor in renderer.report(note, for: key) }
            }
            return HairTryOn.Output(image: image, original: draft.original)
        }
    }

    nonisolated private static func make(photo: CGImage, face: FaceMeasurement, style: Hairstyle, shade: HairTryOn.Shade,
                                         forRepaint: Bool) throws -> HairTryOn.Output {
        guard let url = Res.url(style.imageName, "jpg"), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let bust = AppState.uprightImage(from: source) else { throw HairTryOn.Failure.noBust }
        guard let bustFace = try? FaceAnalyzer.analyze(bust) else { throw HairTryOn.Failure.bustFace }
        return try HairTryOn.render(photo: photo, face: face, bust: bust, bustFace: bustFace, shade: shade, forRepaint: forRepaint,
                                    fadeHeight: style.fadeHeight)
    }

    private func save() {
        guard let output, let data = NSBitmapImageRep(cgImage: output.image).representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "试戴-\(style.name).jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url); flash("已保存") } catch { flash("保存失败：\(error.localizedDescription)") }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }
}

/// Over the picture while the new one is being made: a light that keeps passing across it, and what is being done.
private struct WorkingVeil: View {
    let note: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var passed = false

    var body: some View {
        ZStack {
            Color.white.opacity(0.12)
            if !reduceMotion {
                GeometryReader { area in
                    LinearGradient(colors: [.clear, .white.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: area.size.width * 0.38, height: area.size.height * 1.5)
                        .rotationEffect(.degrees(16))
                        .offset(x: passed ? area.size.width * 1.2 : -area.size.width * 0.6, y: -area.size.height * 0.25)
                        .blendMode(.plusLighter)
                }
                .onAppear { withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: false)) { passed = true } }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text(note).contentTransition(.opacity)
            }
            .font(.fhSmall).foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 30)
            .background(.black.opacity(0.55), in: Capsule())
            .animation(.easeInOut(duration: 0.25), value: note)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 14)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(note)
    }
}

private extension View {
    func panelCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}
