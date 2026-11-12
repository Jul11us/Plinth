import CoreGraphics
import Foundation
import Observation

/// A preview is usable only for the exact photo, hairstyle and shade it was made for.
@MainActor
@Observable
final class TryOnRenderer {
    struct Key: Hashable, Sendable {
        let photoID: UUID
        let styleID: String
        let shadeID: String
    }

    private var results: [Key: HairTryOn.Output] = [:]
    private var order: [Key] = []
    private var activeKey: Key?
    private var lastShown: (key: Key, output: HairTryOn.Output)?
    private var error: String?
    private var refining: Key?
    private var refined: Set<Key> = []
    private var unrefined: Key?
    private var progress: String?
    private var run = UUID()
    private let capacity: Int
    private let showsDrafts: Bool

    /// With `showsDrafts` off, a preview is only handed out once it has been refined, or once refining it has
    /// failed: the draft is a stage of the work, not something to look at.
    init(capacity: Int = 6, showsDrafts: Bool = true) {
        self.capacity = max(1, capacity)
        self.showsDrafts = showsDrafts
    }

    func output(for key: Key) -> HairTryOn.Output? {
        showsDrafts || refined.contains(key) || unrefined == key ? results[key] : nil
    }
    /// The photo framed the way the preview of `key` will be, as soon as that is known.
    func framedPhoto(for key: Key) -> CGImage? { results[key]?.original }
    /// What the work on `key` is doing right now, in words, when whoever does it has said.
    func progress(for key: Key) -> String? { refining == key ? progress : nil }
    func report(_ note: String, for key: Key) { if refining == key { progress = note } }
    /// The last finished preview of the same photo, to keep on screen while `key` is made. Never for saving.
    func standIn(for key: Key) -> HairTryOn.Output? { lastShown?.key.photoID == key.photoID ? lastShown?.output : nil }
    func failure(for key: Key) -> String? { activeKey == key ? error : nil }
    /// The preview of `key` is on screen as a draft and a better one is being made from it.
    func isRefining(_ key: Key) -> Bool { refining == key }
    /// The better preview could not be made, so the draft stays.
    func refineFailed(_ key: Key) -> Bool { unrefined == key }

    func render(_ key: Key, make: () async throws -> HairTryOn.Output) async {
        let run = UUID()
        self.run = run
        activeKey = key
        error = nil
        refining = nil
        unrefined = nil
        progress = nil
        if let ready = results[key] {
            if showsDrafts || refined.contains(key) { lastShown = (key, ready) }
            touch(key)
            return
        }
        do {
            try Task.checkCancellation()
            let output = try await make()
            try Task.checkCancellation()
            guard self.run == run else { return }
            results[key] = output
            if showsDrafts { lastShown = (key, output) }
            touch(key)
            while order.count > capacity {
                let dropped = order.removeFirst()
                results.removeValue(forKey: dropped)
                refined.remove(dropped)
            }
        } catch is CancellationError {
            // A cancelled render must not replace a newer preview or its error state.
        } catch {
            guard self.run == run, !Task.isCancelled else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Replaces the finished preview of `key`, once, with a better one made from it. The draft stays on screen
    /// meanwhile, and stays for good if the better one fails or is overtaken by another render.
    func refine(_ key: Key, make: (HairTryOn.Output) async throws -> HairTryOn.Output) async {
        guard activeKey == key, let draft = results[key], !refined.contains(key) else { return }
        let run = self.run
        refining = key
        unrefined = nil
        progress = nil
        defer { if refining == key { refining = nil; progress = nil } }
        do {
            let better = try await make(draft)
            try Task.checkCancellation()
            guard self.run == run, results[key] != nil else { return }
            results[key] = better
            refined.insert(key)
            if activeKey == key { lastShown = (key, better) }
        } catch is CancellationError {
            // The user moved on; the draft is still a valid preview.
        } catch {
            guard self.run == run, !Task.isCancelled else { return }
            unrefined = key
            if activeKey == key { lastShown = (key, draft) }
        }
    }

    func cancel() {
        run = UUID()
        activeKey = nil
        error = nil
        refining = nil
        unrefined = nil
        progress = nil
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
