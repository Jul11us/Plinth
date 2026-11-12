import CoreGraphics
import Foundation
import Observation

/// Owns a shutter operation so leaving the page cancels both the countdown and the burst.
@MainActor
@Observable
final class CaptureSession {
    private(set) var countdown: Int?
    private(set) var isShooting = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var run = UUID()
    @ObservationIgnored private let sleep: (Duration) async throws -> Void

    init(sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func start(countdownEnabled: Bool, capture: @escaping () async throws -> [CGImage],
               completion: @escaping ([CGImage]) -> Void) {
        guard !isShooting else { return }
        let run = UUID()
        self.run = run
        isShooting = true
        task = Task { @MainActor in
            defer {
                if self.run == run {
                    self.countdown = nil
                    self.isShooting = false
                    self.task = nil
                }
            }
            do {
                if countdownEnabled {
                    for n in stride(from: 3, through: 1, by: -1) {
                        self.countdown = n
                        try await self.sleep(.seconds(1))
                        try Task.checkCancellation()
                        guard self.run == run else { return }
                    }
                }
                self.countdown = 0
                try Task.checkCancellation()
                let frames = try await capture()
                try Task.checkCancellation()
                guard self.run == run, !frames.isEmpty else { return }
                completion(frames)
            } catch is CancellationError {
                // The user left, selected a file, or started a new analysis.
            } catch {
                // Camera startup and framing failures are presented by the capture page.
            }
        }
    }

    @discardableResult
    func cancel() -> Task<Void, Never>? {
        let pending = task
        run = UUID()
        task?.cancel()
        task = nil
        countdown = nil
        isShooting = false
        return pending
    }
}
