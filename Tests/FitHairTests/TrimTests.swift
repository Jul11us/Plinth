import XCTest
import SwiftUI
@testable import FitHair

@MainActor
final class TrimTests: XCTestCase {
    private final class FakeReminder: TrimReminding {
        var allowed = true
        var scheduled: Date?
        var body: String?
        var cancels = 0
        func requestPermission() async -> Bool { allowed }
        func schedule(at date: Date, title: String, body: String) { scheduled = date; self.body = body }
        func cancel() { scheduled = nil; cancels += 1 }
    }

    private var suite: String!
    private var defaults: UserDefaults!
    private let calendar = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        suite = "PlinthTrimTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 1, day: 1 + day, hour: 15))! }

    func testEveryStyleHasAReadableCycle() {
        for style in Hairstyle.all { XCTAssertNotNil(style.trimCycle, style.id) }
        XCTAssertEqual(TrimCycle("6–8 周")?.weeks, 6...8)
        XCTAssertNil(TrimCycle("不用修"))
    }

    func testStatusWordingAcrossTheCycle() throws {
        let cycle = try XCTUnwrap(TrimCycle("6–8 周"))
        func status(_ days: Int) -> TrimCycle.Status { cycle.status(lastCut: date(0), now: date(days), calendar: calendar) }
        XCTAssertEqual(status(0).since, "今天刚剪过")
        XCTAssertEqual(status(3).since, "上次剪发 3 天前")
        XCTAssertEqual(status(35).since, "上次剪发 5 周前")
        XCTAssertEqual(status(35).advice, "建议 1–3 周后修剪")
        XCTAssertEqual(status(35).stage, .early)
        XCTAssertEqual(status(42).stage, .due)
        XCTAssertEqual(status(56).stage, .due)
        XCTAssertEqual(status(57).stage, .overdue)
        XCTAssertEqual(status(57).advice, "比建议的周期多了 1 周，可以约理发师了")
    }

    func testMarkingACutPersistsAndCanBeUndone() {
        let state = AppState(defaults: defaults)
        XCTAssertFalse(state.residesInMenuBar)
        state.markCutToday(now: date(10))
        XCTAssertTrue(state.residesInMenuBar)
        XCTAssertTrue(state.canUndoCut)
        XCTAssertEqual(AppState(defaults: defaults).lastCut, date(10))
        state.undoCut()
        XCTAssertNil(state.lastCut)
        XCTAssertFalse(state.canUndoCut)
        XCTAssertFalse(state.residesInMenuBar)
        XCTAssertNil(AppState(defaults: defaults).lastCut)
    }

    func testCurrentStyleFollowsSavedList() {
        let state = AppState(defaults: defaults)
        XCTAssertNil(state.currentStyle)
        state.toggleSaved("f1")
        state.toggleSaved("f2")
        XCTAssertEqual(state.currentStyle?.id, "f1")
        state.currentStyleID = "f2"
        XCTAssertEqual(AppState(defaults: defaults).currentStyle?.id, "f2")
        state.toggleSaved("f2")
        XCTAssertEqual(state.currentStyle?.id, "f1")
    }

    func testReminderFollowsTheCutAndTheStyle() async throws {
        let fake = FakeReminder()
        let state = AppState(defaults: defaults, reminder: fake)
        state.toggleSaved("f1")
        let ok = await state.setReminders(true)
        XCTAssertTrue(ok)
        XCTAssertNil(fake.scheduled, "nothing to remind about before a cut is recorded")

        let cut = Date()
        state.markCutToday(now: cut)
        let cycle = try XCTUnwrap(state.currentStyle?.trimCycle)
        XCTAssertEqual(fake.scheduled, cycle.reminderDate(lastCut: cut))
        XCTAssertTrue(fake.body?.contains(try XCTUnwrap(state.currentStyle?.name)) == true)

        _ = await state.setReminders(false)
        XCTAssertNil(fake.scheduled)
        XCTAssertFalse(defaults.bool(forKey: "trimReminders"))
    }

    func testRefusedNotificationsLeaveTheSettingOff() async {
        let fake = FakeReminder()
        fake.allowed = false
        let state = AppState(defaults: defaults, reminder: fake)
        let ok = await state.setReminders(true)
        XCTAssertFalse(ok)
        XCTAssertFalse(state.remindersOn)
        XCTAssertFalse(state.residesInMenuBar)
    }

    func testPanelStatesRender() throws {
        let out = ProcessInfo.processInfo.environment["SKETCH_OUT"] ?? NSTemporaryDirectory()
        let state = AppState(defaults: defaults)
        func write(_ name: String) throws {
            let view = StatusPanel(close: {}, showApp: {}).environment(state).background(Color.white)
            let r = ImageRenderer(content: view); r.scale = 2
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(r.cgImage)).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
        }
        try write("panel-empty.png")
        state.toggleSaved("f1")
        state.markCutToday(now: calendar.date(byAdding: .day, value: -35, to: Date())!)
        try write("panel-one.png")
    }

    func testCardTextStaysTheSameForTheMenuBar() {
        let state = AppState(defaults: defaults)
        let style = Hairstyle.all[0]
        let text = BarberExport(state: state).text(for: [style], combined: false)
        XCTAssertTrue(text.hasPrefix("【\(style.name)】给理发师"))
        XCTAssertTrue(text.contains("别这样剪："))
    }

    func testArtworkComesBackAfterBeingReleased() async {
        let first = HairWordArt.shared
        let art = await first.value
        HairWordArt.releaseArtwork()
        let second = HairWordArt.shared
        XCTAssertNotEqual(first, second)
        let again = await second.value
        XCTAssertEqual(art.aspect, again.aspect)
        HairWordArt.releaseArtwork()
    }
}
