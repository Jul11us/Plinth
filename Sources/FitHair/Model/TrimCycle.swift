import Foundation

/// How often a style wants trimming, read from the library's wording ("6–8 周").
struct TrimCycle: Equatable {
    let weeks: ClosedRange<Int>

    init?(_ text: String) {
        let numbers = text.split { !$0.isNumber }.compactMap { Int($0) }
        guard let low = numbers.first, let high = numbers.last, low > 0, low <= high else { return nil }
        weeks = low...high
    }

    struct Status: Equatable {
        enum Stage { case early, due, overdue }
        let stage: Stage
        let since: String
        let advice: String
    }

    func status(lastCut: Date, now: Date = Date(), calendar: Calendar = .current) -> Status {
        let days = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: lastCut), to: calendar.startOfDay(for: now)).day ?? 0)
        let since = days == 0 ? "今天刚剪过" : (days < 7 ? "上次剪发 \(days) 天前" : "上次剪发 \(days / 7) 周前")
        let first = weeks.lowerBound * 7, last = weeks.upperBound * 7
        func weeksUp(_ d: Int) -> Int { (d + 6) / 7 }
        if days < first {
            let soonest = weeksUp(first - days), latest = weeksUp(last - days)
            return Status(stage: .early, since: since, advice: soonest == latest ? "建议 \(soonest) 周后修剪" : "建议 \(soonest)–\(latest) 周后修剪")
        }
        if days <= last { return Status(stage: .due, since: since, advice: "现在可以修剪了") }
        return Status(stage: .overdue, since: since, advice: "比建议的周期多了 \(weeksUp(days - last)) 周，可以约理发师了")
    }

    /// 10 a.m. on the first day the trim is due.
    func reminderDate(lastCut: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: weeks.lowerBound * 7, to: calendar.startOfDay(for: lastCut))
            .flatMap { calendar.date(bySettingHour: 10, minute: 0, second: 0, of: $0) }
    }
}

/// Sends the "time for a trim" notification. A protocol so tests never touch the real notification centre.
protocol TrimReminding {
    func requestPermission() async -> Bool
    func schedule(at date: Date, title: String, body: String)
    func cancel()
}
