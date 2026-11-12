import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Route: Hashable {
    case home, capture, analyzing, result, pool, tryOn, barber
}

/// Where the photo being analysed came from — decides whether the top bar offers "重新拍" or "换一张照片".
enum PhotoSource { case camera, file }

/// What the hairstyle page lists: styles that suit this face shape, everything, or the user's saved ones.
enum StyleScope { case recommended, all, saved }

@MainActor
@Observable
final class AppState {
    @ObservationIgnored private let defaults: UserDefaults
    var route: Route = .home
    /// The home page's opening sequence has played once this launch.
    var introShown = false
    var photo: CGImage?
    private(set) var photoID = UUID()
    var photoSource: PhotoSource = .file
    var measurement: FaceMeasurement?
    var classification: Classification?
    private(set) var shapeConfirmed = false
    var analysisError: String?
    /// The shape the user is browsing — starts as the detected one, can be corrected by hand.
    var shape: FaceShape {
        didSet { defaults.set(shape.rawValue, forKey: "shape") }
    }
    var gender: Gender {
        didSet {
            defaults.set(gender.rawValue, forKey: "gender")
            genderChosen = true
        }
    }
    /// False until someone has picked 女生 or 男生; the first result page then asks instead of assuming.
    private(set) var genderChosen: Bool
    var lengthFilter: HairLength?
    var hairPreferences: HairPreferences {
        didSet { if let data = try? JSONEncoder().encode(hairPreferences) { defaults.set(data, forKey: "hairPreferences") } }
    }
    /// The colour chosen on the try-on page; it also goes on the barber card.
    var hairShade = HairTryOn.Shade.auto {
        didSet { if oldValue.id != hairShade.id { saveResult() } }
    }
    /// Skin undertone and current hair depth read from the photo; nil until one has been measured.
    var colourProfile: ColourProfile?
    /// Which styles the hairstyle page lists.
    var scope: StyleScope = .recommended
    var selectedStyleID: String = "f1"
    var savedStyleIDs: [String] {
        didSet { defaults.set(savedStyleIDs, forKey: "savedStyles") }
    }

    /// Nil keeps nothing between launches (tests); the app passes `.onDisk`.
    init(defaults: UserDefaults = .standard, lastResult: LastResultStore? = nil, reminder: TrimReminding? = nil) {
        self.defaults = defaults
        lastResultStore = lastResult
        self.reminder = reminder
        lastCut = defaults.object(forKey: "lastCut") as? Date
        remindersOn = defaults.bool(forKey: "trimReminders")
        currentStyleID = defaults.string(forKey: "currentStyle")
        savedResultShape = lastResult?.load()?.shape
        genderChosen = defaults.string(forKey: "gender") != nil
        shape = FaceShape(rawValue: defaults.string(forKey: "shape") ?? "") ?? .oval
        gender = Gender(rawValue: defaults.string(forKey: "gender") ?? "") ?? .female
        savedStyleIDs = defaults.stringArray(forKey: "savedStyles") ?? []
        hairPreferences = defaults.data(forKey: "hairPreferences").flatMap { try? JSONDecoder().decode(HairPreferences.self, from: $0) } ?? HairPreferences()
    }

    var selectedStyle: Hairstyle { Hairstyle.all.first { $0.id == selectedStyleID } ?? Hairstyle.all[0] }
    /// The detail pane always belongs to the visible list, including the instant a filter changes.
    var poolSelection: Hairstyle? { pool.first { $0.id == selectedStyleID } ?? pool.first }

    func synchronizePoolSelection() {
        selectedStyleID = poolSelection?.id ?? ""
    }
    var pool: [Hairstyle] {
        if scope == .saved {
            return Hairstyle.pool(for: recommendationScores, gender: gender, length: lengthFilter, preferences: hairPreferences).filter { savedStyleIDs.contains($0.id) }
        }
        return Hairstyle.pool(for: recommendationScores, gender: gender, length: lengthFilter, onlyRecommended: scope == .recommended, preferences: hairPreferences)
    }
    /// How many styles the current gender/length has in all, recommended or not.
    var poolTotal: Int { Hairstyle.pool(for: recommendationScores, gender: gender, length: lengthFilter, preferences: hairPreferences).count }
    /// True once a photo has been measured; the pool can also be browsed without one.
    var hasResult: Bool { classification != nil }
    var usesMixedRecommendations: Bool { classification?.isUncertain == true && !shapeConfirmed && shape == classification?.primary }
    var recommendationScores: [ShapeScore] {
        if usesMixedRecommendations, let classification { return classification.recommendationScores }
        return [.init(shape: shape, probability: 1)]
    }
    var recommendationTarget: String { usesMixedRecommendations ? "相近脸型" : shape.name }
    var suitabilityLabel: String { usesMixedRecommendations ? "综合适合度" : "适合度" }
    func suitability(of style: Hairstyle) -> Int { style.score(for: recommendationScores) }

    var faceSummary: String {
        if usesMixedRecommendations, let classification {
            return "脸型待确认：\(classification.candidateNames)。"
        }
        return "我的脸型：\(shape.name)。" + shape.note
    }

    func chooseShape(_ shape: FaceShape) {
        self.shape = shape
        shapeConfirmed = true
        saveResult()
    }

    /// The result page's way on to the hairstyles.
    func showStyles(for gender: Gender) {
        self.gender = gender
        go(.pool)
    }

    func go(_ r: Route) {
        // Pages cross-fade; the ones with running work cancel it as soon as the route changes (see `onChange(of: route)`).
        withAnimation(.easeInOut(duration: 0.35)) { route = r }
    }

    /// Start a new analysis while keeping the user's saved hairstyles.
    func startOver() {
        clearAnalysis()
        shape = .oval
        lengthFilter = nil
        scope = .recommended
        hairShade = .auto
        selectedStyleID = Hairstyle.pool(for: .oval, gender: gender, length: nil).first?.id ?? "f1"
        go(.home)
    }

    private func clearAnalysis() {
        analysisRun += 1            // whatever is still being measured no longer counts
        photoID = UUID()
        photo = nil; measurement = nil; classification = nil; analysisError = nil; colourProfile = nil
        shapeConfirmed = false
    }

    /// Identifies the latest analysis, so a slower earlier one can't overwrite it when it finishes.
    @ObservationIgnored private var analysisRun = 0

    // MARK: The latest result, kept between launches

    @ObservationIgnored private let lastResultStore: LastResultStore?
    /// Saves run one after another, so an older one can never land on top of a newer one.
    @ObservationIgnored private(set) var pendingSave: Task<Void, Never>?
    /// The shape of the result that can be picked up again; nil when there is none.
    private(set) var savedResultShape: FaceShape?

    private func queueSave(_ work: @escaping @Sendable (LastResultStore) -> Void) {
        guard let store = lastResultStore else { return }
        let previous = pendingSave
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            work(store)
        }
    }

    private func saveResult(photo: CGImage? = nil) {
        guard let measurement else { return }
        let result = LastResult(measurement: measurement, colourProfile: colourProfile, shape: shape, shapeConfirmed: shapeConfirmed,
                                fromCamera: photoSource == .camera, shadeID: hairShade.id)
        if lastResultStore != nil { savedResultShape = shape }
        queueSave { $0.save(result, photo: photo) }
    }

    func resumeLastResult() {
        guard let saved = lastResultStore?.load(),
              let image = lastResultStore?.loadPhoto(matching: saved.measurement.imageSize) else {
            forgetLastResult()
            return
        }
        clearAnalysis()
        hairShade = HairTryOn.Shade.all.first { $0.id == saved.shadeID } ?? .auto
        photo = image
        photoSource = saved.fromCamera ? .camera : .file
        measurement = saved.measurement
        colourProfile = saved.colourProfile
        classification = FaceShapeClassifier.classify(saved.measurement)
        shape = saved.shape
        shapeConfirmed = saved.shapeConfirmed
        go(.result)
    }

    /// Deletes the saved photo and measurement.
    func forgetLastResult() {
        savedResultShape = nil
        queueSave { $0.clear() }
    }

    // MARK: Photos

    func pickPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.message = "选一张正脸自拍"
        if panel.runModal() == .OK, let url = panel.url { load(url: url) }
    }

    func load(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { fail("打不开这个文件。"); return }
        guard let img = Self.uprightImage(from: src) else { fail("打不开这个文件，它可能不是图片。"); return }
        analyze(frames: [img], source: .file)
    }

    /// Decodes a photo the way the app analyses it: EXIF orientation applied, longest side at most 2400 px.
    /// Tests load the reference busts through this too, so their numbers match what the app measures.
    nonisolated static func uprightImage(from src: CGImageSource) -> CGImage? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 2400]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// A file that couldn't be read: show the error without a stale photo from the last analysis behind it.
    private func fail(_ message: String) {
        clearAnalysis()
        analysisError = message
        go(.analyzing)
    }

    func analyze(_ image: CGImage) { analyze(frames: [image], source: .file) }

    /// Measures one photo or a burst of camera frames (median of the frames).
    func analyze(frames: [CGImage], source: PhotoSource) {
        guard let first = frames.last else { return }
        photo = first
        photoID = UUID()
        photoSource = source
        measurement = nil; classification = nil; analysisError = nil; colourProfile = nil
        shapeConfirmed = false
        analysisRun += 1
        let run = analysisRun
        go(.analyzing)
        Task.detached(priority: .userInitiated) {
            let started = Date()
            let outcome: Result<FaceMeasurement, Error> = Result { try FaceAnalyzer.analyze(frames: frames) }
            let profile = (try? outcome.get()).map { ColourAdvisor.profile(photo: frames[min($0.frameIndex, frames.count - 1)], face: $0) }
            // Let the measuring animation play briefly so the step is readable.
            let wait = max(0, 1.6 - Date().timeIntervalSince(started))
            try? await Task.sleep(for: .seconds(wait))
            await MainActor.run {
                guard run == self.analysisRun else { return }
                // The user went back while it was measuring: don't pull them to the result page.
                guard self.route == .analyzing else { self.clearAnalysis(); return }
                switch outcome {
                case .success(let m):
                    self.photo = frames[min(m.frameIndex, frames.count - 1)]
                    self.measurement = m
                    self.colourProfile = profile
                    let c = FaceShapeClassifier.classify(m)
                    self.classification = c
                    self.shape = c.primary
                    self.saveResult(photo: self.photo)
                    self.go(.result)
                case .failure(let e):
                    self.analysisError = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
                }
            }
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in self.load(url: url) } }
            }
            return true
        }
        if p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                Task { @MainActor in self.analyze(cg) }
            }
            return true
        }
        return false
    }

    func toggleSaved(_ id: String) {
        if let i = savedStyleIDs.firstIndex(of: id) { savedStyleIDs.remove(at: i) } else { savedStyleIDs.append(id) }
        syncReminder()
    }

    // MARK: Menu bar: the current style and when it's next due

    @ObservationIgnored private let reminder: TrimReminding?
    private(set) var lastCut: Date? {
        didSet {
            defaults.set(lastCut, forKey: "lastCut")
            syncReminder()
        }
    }
    private(set) var remindersOn: Bool {
        didSet { defaults.set(remindersOn, forKey: "trimReminders") }
    }
    /// Set right after "今天剪了", so a mis-click can be taken back; holds what the date was before.
    private var cutBeforeMark: Date??
    var canUndoCut: Bool { cutBeforeMark != nil }

    var currentStyleID: String? {
        didSet {
            defaults.set(currentStyleID, forKey: "currentStyle")
            syncReminder()
        }
    }
    var savedStyles: [Hairstyle] { savedStyleIDs.compactMap { id in Hairstyle.all.first { $0.id == id } } }
    /// The saved style the menu bar follows.
    var currentStyle: Hairstyle? { savedStyles.first { $0.id == currentStyleID } ?? savedStyles.first }

    /// Closing the window leaves the app in the menu bar only for people using the trim tracking.
    var residesInMenuBar: Bool { lastCut != nil || remindersOn }

    func markCutToday(now: Date = Date()) {
        cutBeforeMark = .some(lastCut)
        lastCut = now
    }

    func undoCut() {
        guard let before = cutBeforeMark else { return }
        cutBeforeMark = nil
        lastCut = before
    }

    /// Returns false when notifications weren't allowed; the setting then stays off.
    func setReminders(_ on: Bool) async -> Bool {
        if on, await reminder?.requestPermission() != true { return false }
        remindersOn = on
        syncReminder()
        return true
    }

    private func syncReminder(now: Date = Date()) {
        guard let reminder else { return }
        guard remindersOn, let lastCut, let style = currentStyle, let cycle = style.trimCycle,
              let date = cycle.reminderDate(lastCut: lastCut), date > now else {
            reminder.cancel()
            return
        }
        reminder.schedule(at: date, title: "该修剪头发了", body: "\(style.name)建议 \(style.cycle)修剪一次，差不多到时候了。")
    }

    /// With no window open, nothing has to stay in memory: the photo is on disk and comes back from the home page.
    func releaseForBackground() {
        clearAnalysis()
        route = .home
        isInBackground = true
    }

    /// True while the app sits in the menu bar with its window closed; the window then draws nothing,
    /// because SwiftUI keeps a closed window's views (and their pictures) alive otherwise.
    private(set) var isInBackground = false

    func returnFromBackground() { isInBackground = false }

    /// The face behind the card, from this session or the saved result.
    var cardContext: (shape: FaceShape?, profile: ColourProfile?) {
        if hasResult { return (shape, colourProfile) }
        let saved = lastResultStore?.load()
        return (saved?.shape, saved?.colourProfile)
    }
}
