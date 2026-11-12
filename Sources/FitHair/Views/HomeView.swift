import SwiftUI
import AVFoundation
import AppKit
import Vision

/// Home: an exhibition room. The app's name is combed out of hair across the wall, then a plaster bust
/// rises in front of it while the word parts around the head and resolves into clean type. The bust slowly morphs through the seven
/// face shapes; a small museum label names the one on display.
struct HomeView: View {
    @Environment(AppState.self) private var state
    @State private var player = MorphPlayer()
    @State private var art: HairWordArt?
    @State private var finishedArt: HairWordArt.Finished?

    // Opening sequence. Runs once per launch; click to skip; skipped with Reduce Motion.
    @State private var growStart: Date?             // the hair is growing while this is set
    @State private var wordShown = false            // the word layer, once growth has begun
    @State private var wordFinished = false         // the sharp finished word is showing
    @State private var wordIsType = false           // the hair has resolved into clean type
    @State private var parted = false               // the word has moved aside for the bust
    @State private var risen = false                // the bust is in place
    @State private var settled = false              // the full picture, with its ground shadow, has replaced the cut-out
    @State private var chromeVisible = false
    @State private var swayStart: Date?             // when the long locks began to move
    @State private var windowVisible = true         // nothing animates while the window is fully hidden
    @State private var introTask: Task<Void, Never>?

    private let shapes = FaceShape.allCases
    /// The busts are 704×880; the video and the segmentation mask are laid out with this.
    private static let exhibitAspect = 704.0 / 880.0
    private static let growDuration = 2.4

    // Where the word sits, as fractions of the page. While alone it is optically centred; behind the bust
    // it is smaller and higher, with a gap so the head stands between "Pli" and "nth" and all six letters read.
    // The gap follows the page height because the bust does; the word gives way on narrow windows.
    private struct WordLayout { let width, centreY, halfGapOfHeight: CGFloat }
    private static let aloneLayout = WordLayout(width: 0.80, centreY: 0.47, halfGapOfHeight: 0)
    private static let behindLayout = WordLayout(width: 0.74, centreY: 0.40, halfGapOfHeight: 0.195)
    private static let wordMargin: CGFloat = 48

    var body: some View {
        GeometryReader { g in page(height: g.size.height) }
            .onAppear { startIntro() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeOcclusionStateNotification)) { _ in
                windowVisible = NSApp.occlusionState.contains(.visible)
                guard introTask == nil else { return }
                if windowVisible { player.play() } else { player.pause() }
            }
            .onDisappear {
                if introTask != nil { introTask?.cancel(); introTask = nil; state.introShown = true }
                player.pause()
            }
    }

    private func page(height: CGFloat) -> some View {
        let shape = shapes[player.labelIndex]
        // Starts just below the window, so the bust is solid from its first frame and never ghosts over the word.
        let rise = risen ? 0 : height * 0.95
        return ZStack {
            if player.ready && !settled {
                // The bust alone, cut from its picture, while it travels.
                exhibit(
                    Image(decorative: player.frames[0], scale: 1).resizable()
                        .mask { if player.masks.count == 7 { personMask(0) } else { Rectangle() } }
                )
                .offset(y: rise)
            }

            // The exhibit: the current still with the next one dissolving in over it.
            exhibit(
                ZStack {
                    if player.ready {
                        Image(decorative: player.frames[player.index], scale: 1).resizable()
                        Image(decorative: player.frames[player.next], scale: 1).resizable().opacity(player.progress)
                    }
                }
            )
            .mask { exhibit(Rectangle().padding(30).blur(radius: 26)) }
            .opacity(player.ready && settled ? 1 : 0)
            .accessibilityLabel("石膏胸像在七种脸型之间慢慢变化，现在是\(shape.name)")

            hairWord(rise: rise)
                // Without masks the word would lie across the face, so it leaves when the bust arrives.
                .opacity(wordShown && art != nil && (player.masks.count == 7 || !risen) ? 1 : 0)

            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: 24) {
                    label(for: shape)
                    Spacer()
                    invitation
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 32)
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)

            if introTask != nil {
                Color.clear.contentShape(Rectangle()).onTapGesture { finishIntro() }
            }
        }
    }

    // MARK: Opening

    private func startIntro() {
        let loading = Task { await player.load() }
        let artLoading = Task { @MainActor in art = await HairWordArt.shared.value }
        let finishing = Task { @MainActor in
            finishedArt = await HairWordArt.finished.value
            if state.introShown { finishedArt?.releaseLooseHair() }
        }
        if state.introShown || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            showFinalState()
            state.introShown = true
            player.play()
            return
        }
        introTask = Task { @MainActor in
            do {
                await artLoading.value
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(200))
                wordShown = true
                growStart = Date()
                try await Task.sleep(for: .seconds(Self.growDuration))
                await finishing.value
                try Task.checkCancellation()
                // The sharp finished word fades up over the softer growth slices, so the swap can't be seen.
                withAnimation(.easeInOut(duration: 0.35)) { wordFinished = true }
                try await Task.sleep(for: .milliseconds(350))
                growStart = nil
                art?.growth.slices = []             // tens of MB, and never needed again
                try await Task.sleep(for: .milliseconds(450))
                await loading.value
                try Task.checkCancellation()

                // The word draws aside just ahead of the head reaching it.
                withAnimation(.timingCurve(0.5, 0, 0.2, 1, duration: 1.5)) { parted = true }
                withAnimation(.easeInOut(duration: 1.1)) { wordIsType = true }     // the hair resolves into type as it moves
                withAnimation(.timingCurve(0.2, 0.75, 0.2, 1, duration: 1.8)) { risen = true }
                try await Task.sleep(for: .milliseconds(1800))

                swayStart = Date()
                withAnimation(.easeInOut(duration: 0.6)) { settled = true }
                withAnimation(.easeOut(duration: 0.6)) { chromeVisible = true }
                player.play()
                state.introShown = true
                introTask = nil
                finishedArt?.releaseLooseHair()
            } catch {}                              // skipped, or the user left the page
        }
    }

    private func showFinalState() {
        growStart = nil; wordShown = true; wordFinished = true; wordIsType = true; parted = true; risen = true; settled = true; chromeVisible = true
        if swayStart == nil { swayStart = Date() }
    }

    private func finishIntro() {
        introTask?.cancel(); introTask = nil
        withAnimation(.easeOut(duration: 0.45)) { showFinalState() }
        state.introShown = true
        player.play()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))      // after the fade
            finishedArt?.releaseLooseHair()
        }
    }

    // MARK: The word

    /// The word in hair. `rise` keeps the hole for the bust locked to the travelling bust.
    /// The long locks sit outside the mask: they never reach the bust, and moving them would otherwise
    /// make the whole cut-out recomposite on every frame.
    @ViewBuilder private func hairWord(rise: CGFloat) -> some View {
        if let art {
            ZStack {
                wordLayer(art) { size, gap in
                    if let start = growStart { growingWord(art, size: size, since: start) }
                    if let done = finishedArt {
                        if let left = done.left { placed(left, in: size).offset(x: -gap).opacity(wordFinished && !wordIsType ? 1 : 0) }
                        if let right = done.right { placed(right, in: size).offset(x: gap).opacity(wordFinished && !wordIsType ? 1 : 0) }
                        placed(done.leftType, in: size).offset(x: -gap).opacity(wordIsType ? 1 : 0)
                        placed(done.rightType, in: size).offset(x: gap).opacity(wordIsType ? 1 : 0)
                    }
                }
                .mask {
                    ZStack {
                        Rectangle()
                        if player.masks.count == 7 {
                            // Blend the two frames' masks exactly as the picture blends the frames, then cut them out.
                            exhibit(
                                ZStack {
                                    personMask(player.index).opacity(1 - player.progress).blendMode(.plusLighter)
                                    personMask(player.next).opacity(player.progress).blendMode(.plusLighter)
                                }
                                .compositingGroup()
                                .blur(radius: 1.2)
                            )
                            .offset(y: rise)
                            .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
                }

                // One layer from the end of the growth onwards: only the letters change from hair to type.
                wordLayer(art) { size, gap in
                    if let done = finishedArt {
                        swayingLock(done.leftLock, root: done.leftLockRoot, degrees: 1.7, period: 7.5, in: size)
                            .offset(x: -gap).opacity(wordFinished ? 1 : 0)
                        swayingLock(done.rightLock, root: done.rightLockRoot, degrees: -1.3, period: 9.5, in: size)
                            .offset(x: gap).opacity(wordFinished ? 1 : 0)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Positions the word's layers: the same place, size and gap for the letters and for the locks.
    private func wordLayer<C: View>(_ art: HairWordArt, @ViewBuilder content: @escaping (CGSize, CGFloat) -> C) -> some View {
        GeometryReader { g in
            let l = parted ? Self.behindLayout : Self.aloneLayout
            let gap = g.size.height * l.halfGapOfHeight
            let word = min(g.size.width * l.width, g.size.width - 2 * (gap + Self.wordMargin))
            let w = word * HairWordArt.paddedScale
            let size = CGSize(width: w, height: w / art.aspect)
            ZStack { content(size, gap) }
                .frame(width: size.width, height: size.height)
                .position(x: g.size.width / 2, y: g.size.height * l.centreY)
        }
    }

    /// A cropped bitmap at its place in the word.
    private func placed(_ p: HairWordArt.Placed, in size: CGSize) -> some View {
        Image(decorative: p.image, scale: 1).resizable()
            .frame(width: p.frame.width * size.width, height: p.frame.height * size.height)
            .offset(x: p.frame.minX * size.width, y: p.frame.minY * size.height)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func personMask(_ i: Int) -> some View {
        ZStack {
            Color.black
            Image(decorative: player.masks[i], scale: 1).resizable()
        }
        .compositingGroup()
        .luminanceToAlpha()
    }

    /// A long lock turning a degree or two about the point where it leaves its letter, as if in still air.
    /// It rests until the word has settled, then eases into the movement.
    private func swayingLock(_ lock: HairWordArt.Placed, root: CGPoint, degrees: Double, period: Double, in size: CGSize) -> some View {
        let still = swayStart == nil || !windowVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // So slow that 20 updates a second is indistinguishable from 60.
        return TimelineView(.animation(minimumInterval: 1.0 / 20, paused: still)) { context in
            let t = swayStart.map { context.date.timeIntervalSince($0) } ?? 0
            let ease = min(1, t / 4)
            Image(decorative: lock.image, scale: 1).resizable()
                .frame(width: lock.frame.width * size.width, height: lock.frame.height * size.height)
                .rotationEffect(.degrees(still ? 0 : degrees * ease * ease * (3 - 2 * ease) * sin(2 * .pi * t / period)),
                                anchor: UnitPoint(x: root.x, y: root.y))
                .offset(x: lock.frame.minX * size.width, y: lock.frame.minY * size.height)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    /// Each slice of the growth fades up as its moment passes; together they draw every strand out.
    private func growingWord(_ art: HairWordArt, size: CGSize, since start: Date) -> some View {
        TimelineView(.animation) { context in
            let t = min(1, context.date.timeIntervalSince(start) / Self.growDuration)
            let now = 1 - pow(1 - t, 1.5)        // starts at once, settles gently
            ZStack(alignment: .topLeading) {
                ForEach(art.growth.slices.indices.filter { art.growth.slices[$0].time < now }, id: \.self) { i in
                    let s = art.growth.slices[i]
                    Image(decorative: s.image, scale: 1).resizable()
                        .frame(width: s.frame.width * size.width, height: s.frame.height * size.height)
                        .offset(x: s.frame.minX * size.width, y: s.frame.minY * size.height)
                        .opacity(min(1, (now - s.time) / 0.03))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    /// Lays a view out exactly where the video is drawn, so a mask image lines up with the bust.
    private func exhibit<V: View>(_ v: V) -> some View {
        v.aspectRatio(Self.exhibitAspect, contentMode: .fit)
            .padding(.top, -24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Museum-style wall label: what's on display, plus the seven names to jump between.
    private func label(for shape: FaceShape) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("七种脸型 · \(player.labelIndex + 1) / 7")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                Text(shape.name)
                    .font(.system(size: 24, weight: .semibold))
                Text(shape.hairLine)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: 0x2B2B2B))
            }
            .id(shape)
            .transition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.6), value: shape)

            Rectangle().fill(Color(hex: 0xE2E0DC)).frame(height: 1).padding(.vertical, 12)

            // Seven small pills: comfortable to click, the current one filled.
            HStack(spacing: 2) {
                ForEach(Array(shapes.enumerated()), id: \.offset) { i, s in
                    let on = i == player.labelIndex
                    Button { player.jump(to: i) } label: {
                        Text(s.short)
                            .font(.system(size: 12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.ink : Color.fhSecondary)
                            .padding(.horizontal, 7).frame(height: 26)
                            .background(on ? Theme.paper : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("看\(s.name)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.leading, -7)
            .animation(.easeInOut(duration: 0.4), value: player.labelIndex)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(width: 272, alignment: .leading)
        .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }

    private var invitation: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Text("你是哪一种？")
                .font(.system(size: 22, weight: .medium))
            HStack(spacing: 14) {
                Button("从相册选一张") { state.pickPhoto() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .underline()
                Button { state.go(.capture) } label: {
                    Text("拍一张")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 40)
                        .background(Theme.ink, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            Text("照片只在这台 Mac 上分析，也可以直接拖进窗口")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            Button("不拍照，先看看发型库") { state.go(.pool) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.fhSecondary)
                .underline()
                .padding(.top, 2)
            if let shape = state.savedResultShape {
                HStack(spacing: 8) {
                    Button("接着看上次的结果（\(shape.name)）") { state.resumeLastResult() }
                        .underline()
                    Button("删除") { state.forgetLastResult() }
                        .foregroundStyle(Theme.muted)
                        .help("删除保存在这台 Mac 上的上次照片和测量结果")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.fhSecondary)
            }
        }
    }
}

/// The exhibit: seven bust frames (pulled from the bundled morph video once, at launch) shown one after
/// another with an eased dissolve that the app drives itself, plus a person-segmentation mask for each
/// frame. Driving the dissolve here, rather than playing the video, keeps the picture, the wall text and
/// its cut-out in lock-step: the mask during a dissolve is the same linear blend of the two frames' masks
/// as the picture is of the two frames, so nothing flickers or lags.
@MainActor
@Observable
final class MorphPlayer {
    /// Layout of the source video: 2.6 s per shape, hold then morph; the still is sampled mid-hold.
    nonisolated static let videoSegment = 2.6
    /// Our own pacing.
    static let hold = 1.8, fade = 1.2

    private(set) var frames: [CGImage] = []
    private(set) var masks: [CGImage] = []
    /// The shape on display, the one it is dissolving into, and how far along (0 = holding `index`).
    private(set) var index = 0
    private(set) var next = 1
    private(set) var progress: Double = 0
    /// For the label: switches halfway through the dissolve.
    var labelIndex: Int { progress < 0.5 ? index : next }
    var ready: Bool { frames.count == 7 }

    @ObservationIgnored private var anchor = Date()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wantsPlay = false

    /// Decoded once per run: SwiftUI re-creates a view's @State initial value on every parent update,
    /// so loading in `init` would repeat this work (seven frames, seven segmentations) each time.
    nonisolated private static let exhibit = Reloadable { loadExhibit() }
    /// For when the app stays in the menu bar with no window open.
    nonisolated static func releaseExhibit() { exhibit.release() }

    func load() async {
        guard !ready else { return }
        let (frames, masks) = await Self.exhibit.value.value
        self.frames = frames; self.masks = masks
        anchor = Date()
        if wantsPlay { startTimer() }
    }

    func play() {
        wantsPlay = true
        anchor = Date()
        if ready { startTimer() }
    }

    func pause() {
        wantsPlay = false
        timer?.invalidate(); timer = nil
    }

    /// Dissolve to shape `i` right away, then carry on from there.
    func jump(to i: Int) {
        guard i != index || progress > 0 else { return }
        if progress > 0 { index = next }        // mid-dissolve: start from the one we're mostly showing
        next = i
        anchor = Date().addingTimeInterval(-Self.hold)
        progress = 0.001
        if !ready || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            index = i; progress = 0; anchor = Date()
        }
        startTimer()
    }

    /// Sleeps through the hold and only ticks at 60 Hz while a dissolve is actually running.
    private func startTimer() {
        timer?.invalidate(); timer = nil
        guard wantsPlay, ready, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let wait = Self.hold - Date().timeIntervalSince(anchor)
        if wait > 0 {
            timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.startTimer() }
            }
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(anchor)
        if elapsed < Self.hold {
            if progress != 0 { progress = 0 }
        } else if elapsed < Self.hold + Self.fade {
            let t = (elapsed - Self.hold) / Self.fade
            progress = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2   // ease in-out
        } else {
            index = next
            next = (index + 1) % 7
            progress = 0
            anchor = Date().addingTimeInterval(-(elapsed - Self.hold - Self.fade))
            startTimer()
        }
    }

    // MARK: Loading

    /// One still per shape from the morph video (falls back to the bust photos), and its bust mask.
    nonisolated private static func loadExhibit() -> ([CGImage], [CGImage]) {
        var frames: [CGImage] = []
        if let url = Res.url("morph", "mp4") {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            for i in 0..<7 {
                let t = CMTime(seconds: Double(i) * videoSegment + 0.8, preferredTimescale: 600)
                if let cg = try? gen.copyCGImage(at: t, actualTime: nil) { frames.append(cg) }
            }
        }
        if frames.count != 7 {
            frames = FaceShape.allCases.compactMap { Res.image($0.imageName).cgImage(forProposedRect: nil, context: nil, hints: nil) }
        }
        let masks = frames.compactMap(personMask)
        return (frames, masks.count == frames.count ? masks : [])
    }

    /// Vision person segmentation; plaster busts count as people. Returns an 8-bit gray image.
    nonisolated private static func personMask(_ image: CGImage) -> CGImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        guard let m = req.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(m, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(m, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(m) else { return nil }
        let w = CVPixelBufferGetWidth(m), h = CVPixelBufferGetHeight(m), bpr = CVPixelBufferGetBytesPerRow(m)
        let data = Data(bytes: base, count: bpr * h)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bpr,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
