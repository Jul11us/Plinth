import CryptoKit
import Foundation

/// Fetches the image model of the realistic try-on as one zip archive (made by `scripts/pack-model.sh`) and unpacks
/// it into place. The archive is checked against the SHA-256 the app was built with before it is opened, a
/// download that was cut off goes on where it stopped, and the model folder only appears once it is complete.
enum RepaintModelDownload {
    enum Failure: LocalizedError, Equatable {
        case notConfigured, insecure, unpinned, wrongArchive, incomplete, noSpace(needed: Int64)
        case server(Int), unpack(String), network(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "这个版本没有配置模型的下载地址。"
            case .insecure: "模型的下载地址不是 https，已拒绝。"
            case .unpinned: "这个版本没有写明模型压缩包的校验值，已拒绝下载。"
            case .wrongArchive: "下载到的压缩包和这个版本要的不是同一份（校验没通过），已删除。请重试。"
            case .incomplete: "压缩包里缺少模型必要的文件。"
            case .noSpace(let needed): "磁盘空间不够，还需要约 \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))。"
            case .server(let code): "下载服务器返回了错误（\(code)）。"
            case .unpack(let what): "解压没成功：\(what)"
            case .network(let what): "下载中断了：\(what)"
            }
        }
    }

    enum Step: Equatable, Sendable {
        case downloading(done: Int64, total: Int64)
        case unpacking
    }

    /// Where the archive is, and the SHA-256 it must have (lower-case hex).
    struct Source: Equatable {
        let archive: URL
        var sha256: String? = nil
    }

    /// From the app's Info.plist (`PlinthRepaintModelURL`, `PlinthRepaintModelSHA256`), or from the environment
    /// for development (`PLINTH_MODEL_URL`, `PLINTH_MODEL_SHA256`). nil when this build has nowhere to download from.
    static var configured: Source? {
        let environment = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        let fromEnvironment = environment["PLINTH_MODEL_URL"].flatMap { $0.isEmpty ? nil : $0 }
        guard let text = fromEnvironment ?? info["PlinthRepaintModelURL"] as? String, !text.isEmpty, let archive = URL(string: text)
        else { return nil }
        let pinned = fromEnvironment == nil ? info["PlinthRepaintModelSHA256"] as? String : environment["PLINTH_MODEL_SHA256"]
        return Source(archive: archive, sha256: pinned.flatMap { $0.isEmpty ? nil : $0.lowercased() })
    }

    /// The archive on a server on this Mac or in a folder: how a download is tried out before anything is published.
    static func isLocal(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "file": true
        case "http", "https": ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
        default: false
        }
    }

    /// The model unpacked, and the archive beside it while both exist.
    static let spaceNeeded: Int64 = 4_600_000_000

    /// Downloads and unpacks the archive of `source` into `folder`. `required` is what has to be in the folder for
    /// the model to count as installed.
    static func install(from source: Source, into folder: URL, required: [String],
                        progress: @escaping @Sendable (Step) -> Void = { _ in }) async throws {
        let local = isLocal(source.archive)
        guard local || source.archive.scheme?.lowercased() == "https" else { throw Failure.insecure }
        // What comes from the internet is unpacked only if it is exactly the archive this build was made for.
        guard local || source.sha256 != nil else { throw Failure.unpinned }

        let files = FileManager.default
        let parent = folder.deletingLastPathComponent(), name = folder.lastPathComponent
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let archive = parent.appendingPathComponent(name + ".zip.part")
        let leftover = parent.appendingPathComponent(name + ".resume")
        let staging = parent.appendingPathComponent(name + ".unpacking")

        // 1. The archive, unless an earlier try already got all of it.
        let fetched = files.fileExists(atPath: archive.path) && source.sha256 != nil && (try? sha256(of: archive)) == source.sha256
        if !fetched {
            try? files.removeItem(at: archive)
            if let free = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free < spaceNeeded { throw Failure.noSpace(needed: spaceNeeded - free) }
            let fetcher = Fetcher()
            defer { fetcher.finish() }
            do {
                try await fetcher.fetch(source.archive, to: archive, resuming: try? Data(contentsOf: leftover)) { done, total in
                    progress(.downloading(done: done, total: total))
                }
                try? files.removeItem(at: leftover)
            } catch {
                // What has arrived is kept by the system for a while; this is the ticket to go on with it.
                if let ticket = fetcher.resumeData { try? ticket.write(to: leftover) } else { try? files.removeItem(at: leftover) }
                throw error
            }
        }

        // 2. Is it the right one?
        try Task.checkCancellation()
        progress(.unpacking)
        if let wanted = source.sha256, try sha256(of: archive) != wanted {
            try? files.removeItem(at: archive)
            throw Failure.wrongArchive
        }

        // 3. Unpacked beside the final place, looked over, then moved there in one go.
        try? files.removeItem(at: staging)
        defer { try? files.removeItem(at: staging) }
        try unpack(archive, into: staging)
        try Task.checkCancellation()
        let root = try modelRoot(in: staging, required: required)
        if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
        try files.moveItem(at: root, to: folder)
        try? files.removeItem(at: archive)
    }

    /// Where the model is inside what was unpacked: at the top, or in the one folder the archive wrapped it in.
    /// An archive is only data to be read as a model: a link in it could lead anywhere, so there may be none.
    static func modelRoot(in unpacked: URL, required: [String]) throws -> URL {
        let files = FileManager.default
        func complete(_ folder: URL) -> Bool { required.allSatisfy { files.fileExists(atPath: folder.appendingPathComponent($0).path) } }
        var root = unpacked
        if !complete(root) {
            let inside = (try? files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isDirectoryKey]))?
                .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" } ?? []
            guard inside.count == 1, complete(inside[0]) else { throw Failure.incomplete }
            root = inside[0]
        }
        let walker = files.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
        while let item = walker?.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Failure.unpack("压缩包里有不该有的链接") }
        }
        return root
    }

    private static func unpack(_ archive: URL, into folder: URL) throws {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        tool.arguments = ["-x", "-k", archive.path, folder.path]
        let complaints = Pipe()
        tool.standardError = complaints
        tool.standardOutput = FileHandle.nullDevice
        do { try tool.run() } catch { throw Failure.unpack(error.localizedDescription) }
        let said = complaints.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0 else {
            throw Failure.unpack(String(data: said, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ditto \(tool.terminationStatus)")
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One file to a place on disk, reporting how much has arrived. A transfer that breaks is picked up where it
    /// stopped, a few times, before it is given up; what is left of it then is in `resumeData`.
    private final class Fetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var session: URLSession!
        private var destination: URL?
        private var report: (@Sendable (Int64, Int64) -> Void)?
        private var waiting: CheckedContinuation<Void, Error>?
        private var moved: Error?
        private var status = 200
        private var current: URLSessionDownloadTask?
        private var ticket: Data?
        private static let attempts = 4

        var resumeData: Data? { lock.withLock { ticket } }
        private func keep(_ left: Data) { lock.withLock { ticket = left } }

        override init() {
            super.init()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        }

        func finish() { session.invalidateAndCancel() }

        func fetch(_ url: URL, to place: URL, resuming earlier: Data?, written: @escaping @Sendable (Int64, Int64) -> Void) async throws {
            var resume = earlier
            for attempt in 1...Self.attempts {
                do {
                    try await once(resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url),
                                   to: place, written: written)
                    return
                } catch let failure as Failure {
                    throw failure
                } catch {
                    let broken = error as NSError
                    resume = broken.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                    if let resume { keep(resume) }
                    if error is CancellationError || broken.code == NSURLErrorCancelled || Task.isCancelled { throw CancellationError() }
                    guard attempt < Self.attempts else { throw Failure.network(broken.localizedDescription) }
                    try await Task.sleep(for: .seconds(Double(attempt)))
                }
            }
        }

        private func once(_ task: URLSessionDownloadTask, to place: URL, written: @escaping @Sendable (Int64, Int64) -> Void) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    destination = place; report = written; waiting = continuation; moved = nil; status = 200; current = task; ticket = nil
                    lock.unlock()
                    task.resume()
                }
            } onCancel: {
                lock.lock(); let running = current; lock.unlock()
                // Stopping on purpose keeps what has arrived, like a broken transfer does.
                running?.cancel { [weak self] left in
                    if let left { self?.keep(left) }
                }
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            lock.lock(); let report = report; lock.unlock()
            report?(totalBytesWritten, max(totalBytesExpectedToWrite, totalBytesWritten))
        }

        // The file is only there for the length of this call.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            lock.lock(); defer { lock.unlock() }
            if let answer = downloadTask.response as? HTTPURLResponse { status = answer.statusCode }
            guard (200..<300).contains(status), let destination else { return }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch { moved = error }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let continuation = waiting, moved = moved, status = status
            waiting = nil; current = nil
            lock.unlock()
            if let error { continuation?.resume(throwing: error) }
            else if !(200..<300).contains(status) { continuation?.resume(throwing: Failure.server(status)) }
            else if let moved { continuation?.resume(throwing: moved) }
            else { continuation?.resume() }
        }
    }
}

/// The state of the model on this Mac, for the try-on page: there, on offer, on its way, or failed.
@MainActor
@Observable
final class RepaintModelInstaller {
    enum Phase: Equatable {
        /// Not installed, and this build can't download it.
        case unavailable
        case offered
        /// Stopped part-way, with what has arrived kept to go on from.
        case paused
        case downloading(done: Int64, total: Int64)
        case unpacking
        case failed(String)
        case installed

        var isBusy: Bool {
            switch self {
            case .downloading, .unpacking: true
            default: false
            }
        }
    }

    static let shared = RepaintModelInstaller()

    private(set) var phase: Phase
    private var work: Task<Void, Never>?
    private let source: RepaintModelDownload.Source?
    private let folder: URL
    private let required: [String]

    init(source: RepaintModelDownload.Source? = RepaintModelDownload.configured, folder: URL = HairRepaint.folder,
         required: [String] = HairRepaint.files) {
        self.source = source
        self.folder = folder
        self.required = required
        let files = FileManager.default
        let there = required.allSatisfy { files.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let begun = [".resume", ".zip.part"].contains { files.fileExists(atPath: folder.path + $0) }
        phase = there ? .installed : (source == nil ? .unavailable : (begun ? .paused : .offered))
    }

    /// Starts the download, or goes on with one that stopped. Does nothing while one is running.
    func start() {
        guard work == nil, phase != .installed, let source else { return }
        phase = .downloading(done: 0, total: 0)
        let folder = folder, required = required
        work = Task { [weak self] in
            do {
                try await RepaintModelDownload.install(from: source, into: folder, required: required) { step in
                    Task { @MainActor in
                        // Late reports of a download that has ended change nothing.
                        guard let self, self.phase.isBusy else { return }
                        switch step {
                        case .downloading(let done, let total): self.phase = .downloading(done: done, total: total)
                        case .unpacking: self.phase = .unpacking
                        }
                    }
                }
                self?.phase = .installed
            } catch is CancellationError {
                self?.phase = .paused
            } catch {
                self?.phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.work = nil
        }
    }

    /// What has arrived is kept, so starting again goes on from there.
    func cancel() { work?.cancel() }

    /// For tests: the download that is running, to wait for.
    func finished() async { await work?.value }
}
