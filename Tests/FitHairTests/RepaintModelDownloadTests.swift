import XCTest
@testable import FitHair

/// The model of the realistic try-on arrives as one zip archive. These go through a download with a small
/// stand-in archive in a folder on this Mac: nothing here touches the network or the installed model.
final class RepaintModelDownloadTests: XCTestCase {
    private var scratch: URL!
    private let required = ["Net.mlmodelc", "vocab.json"]

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("plinth-download-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A folder that looks like a model, zipped the way `scripts/pack-model.sh` does it.
    private func archive(named name: String = "model.zip", wrapped: Bool = false, leavingOut missing: String? = nil,
                         withLink: Bool = false) throws -> (url: URL, sha256: String) {
        let model = scratch.appendingPathComponent("source-\(UUID().uuidString)/RepaintModel")
        try FileManager.default.createDirectory(at: model.appendingPathComponent("Net.mlmodelc/weights"), withIntermediateDirectories: true)
        try Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: model.appendingPathComponent("Net.mlmodelc/weights/weight.bin"))
        try Data("{}".utf8).write(to: model.appendingPathComponent("Net.mlmodelc/metadata.json"))
        try Data(#"{"a": 1}"#.utf8).write(to: model.appendingPathComponent("vocab.json"))
        if let missing { try FileManager.default.removeItem(at: model.appendingPathComponent(missing)) }
        if withLink { try FileManager.default.createSymbolicLink(atPath: model.appendingPathComponent("escape").path, withDestinationPath: "/etc") }

        let zip = scratch.appendingPathComponent(name)
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        tool.arguments = ["-c", "-k", "--norsrc"] + (wrapped ? ["--keepParent"] : []) + [model.path, zip.path]
        try tool.run()
        tool.waitUntilExit()
        XCTAssertEqual(tool.terminationStatus, 0)
        return (zip, try RepaintModelDownload.sha256(of: zip))
    }

    private var folder: URL { scratch.appendingPathComponent("installed/RepaintModel") }
    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path).filter { $0 != "RepaintModel" }
    }

    func testAnArchiveIsDownloadedCheckedAndUnpackedIntoPlace() async throws {
        let packed = try archive()
        let steps = Steps()
        try await RepaintModelDownload.install(from: .init(archive: packed.url, sha256: packed.sha256), into: folder, required: required) {
            steps.add($0)
        }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Net.mlmodelc/weights/weight.bin")).count, 200_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("vocab.json").path))
        // Nothing of the download is left beside the model.
        XCTAssertEqual(try leftovers(), [])
        XCTAssertEqual(steps.all.last, .unpacking)
        XCTAssertTrue(steps.all.contains { if case .downloading = $0 { true } else { false } })
    }

    func testAnArchiveThatIsNotTheOneTheAppWasBuiltForIsRefused() async throws {
        let packed = try archive()
        let other = String(repeating: "0", count: 64)
        do {
            try await RepaintModelDownload.install(from: .init(archive: packed.url, sha256: other), into: folder, required: required)
            XCTFail("installed an archive with the wrong checksum")
        } catch let failure as RepaintModelDownload.Failure {
            XCTAssertEqual(failure, .wrongArchive)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try leftovers(), [])
    }

    func testTheModelMayBeWrappedInOneFolderInsideTheArchive() async throws {
        let packed = try archive(wrapped: true)
        try await RepaintModelDownload.install(from: .init(archive: packed.url, sha256: packed.sha256), into: folder, required: required)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Net.mlmodelc/metadata.json").path))
    }

    func testAnArchiveWithoutAllOfTheModelInstallsNothing() async throws {
        let packed = try archive(leavingOut: "vocab.json")
        do {
            try await RepaintModelDownload.install(from: .init(archive: packed.url, sha256: packed.sha256), into: folder, required: required)
            XCTFail("installed half a model")
        } catch let failure as RepaintModelDownload.Failure {
            XCTAssertEqual(failure, .incomplete)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testAnArchiveWithALinkInItInstallsNothing() async throws {
        let packed = try archive(withLink: true)
        do {
            try await RepaintModelDownload.install(from: .init(archive: packed.url, sha256: packed.sha256), into: folder, required: required)
            XCTFail("installed an archive with a link in it")
        } catch let failure as RepaintModelDownload.Failure {
            guard case .unpack = failure else { return XCTFail("\(failure)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// Before anything is fetched: only https from the internet, and only with the checksum to hold it to.
    func testOnlyAPinnedHttpsArchiveIsFetchedFromTheInternet() async throws {
        let plain = RepaintModelDownload.Source(archive: URL(string: "http://example.com/RepaintModel.zip")!, sha256: String(repeating: "a", count: 64))
        let unpinned = RepaintModelDownload.Source(archive: URL(string: "https://example.com/RepaintModel.zip")!)
        for (source, expected) in [(plain, RepaintModelDownload.Failure.insecure), (unpinned, .unpinned)] {
            do {
                try await RepaintModelDownload.install(from: source, into: folder, required: required)
                XCTFail("started a download from \(source.archive)")
            } catch let failure as RepaintModelDownload.Failure {
                XCTAssertEqual(failure, expected)
            }
        }
        XCTAssertTrue(RepaintModelDownload.isLocal(URL(string: "http://127.0.0.1:8000/RepaintModel.zip")!))
        XCTAssertFalse(RepaintModelDownload.isLocal(URL(string: "https://example.com/RepaintModel.zip")!))
    }

    /// An archive that arrived whole before the app was quit is not fetched a second time.
    func testAnArchiveThatAlreadyArrivedIsUsed() async throws {
        let packed = try archive()
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: packed.url, to: folder.deletingLastPathComponent().appendingPathComponent("RepaintModel.zip.part"))
        let gone = scratch.appendingPathComponent("no-longer-there.zip")
        try await RepaintModelDownload.install(from: .init(archive: gone, sha256: packed.sha256), into: folder, required: required)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("vocab.json").path))
        XCTAssertEqual(try leftovers(), [])
    }

    /// An app packaged with the model uses that one and needs no download; otherwise the model is the one in
    /// Application Support.
    func testAModelPackagedWithTheAppIsUsedFirst() throws {
        let support = scratch.appendingPathComponent("support"), packaged = scratch.appendingPathComponent("app/RepaintModel")
        let outside = support.appendingPathComponent("Plinth/RepaintModel")
        XCTAssertEqual(HairRepaint.folder(override: nil, packaged: packaged, support: support), outside)
        XCTAssertEqual(HairRepaint.folder(override: nil, packaged: nil, support: support), outside)

        // Half a model inside the app doesn't count.
        try FileManager.default.createDirectory(at: packaged, withIntermediateDirectories: true)
        try Data().write(to: packaged.appendingPathComponent("vocab.json"))
        XCTAssertEqual(HairRepaint.folder(override: nil, packaged: packaged, support: support), outside)
        for name in HairRepaint.files { try Data().write(to: packaged.appendingPathComponent(name)) }
        XCTAssertEqual(HairRepaint.folder(override: nil, packaged: packaged, support: support), packaged)

        XCTAssertEqual(HairRepaint.folder(override: "/tmp/elsewhere", packaged: packaged, support: support).path, "/tmp/elsewhere")
        XCTAssertEqual(HairRepaint.folder(override: "", packaged: packaged, support: support), packaged)
    }

    @MainActor
    func testTheInstallerGoesFromOfferedToInstalledOrSaysWhatWentWrong() async throws {
        XCTAssertEqual(RepaintModelInstaller(source: nil, folder: folder, required: required).phase, .unavailable)

        let packed = try archive()
        let installer = RepaintModelInstaller(source: .init(archive: packed.url, sha256: packed.sha256), folder: folder, required: required)
        XCTAssertEqual(installer.phase, .offered)
        installer.start()
        XCTAssertTrue(installer.phase.isBusy)
        await installer.finished()
        XCTAssertEqual(installer.phase, .installed)
        // And it is found there the next time.
        XCTAssertEqual(RepaintModelInstaller(source: nil, folder: folder, required: required).phase, .installed)

        let elsewhere = scratch.appendingPathComponent("second/RepaintModel")
        let failing = RepaintModelInstaller(source: .init(archive: packed.url, sha256: String(repeating: "0", count: 64)),
                                            folder: elsewhere, required: required)
        failing.start()
        await failing.finished()
        guard case .failed(let why) = failing.phase else { return XCTFail("\(failing.phase)") }
        XCTAssertTrue(why.contains("校验"))
        // Trying again is possible.
        failing.start()
        XCTAssertTrue(failing.phase.isBusy)
        await failing.finished()

        // A download that was stopped part-way is offered as one to go on with, also after a relaunch.
        let third = scratch.appendingPathComponent("third/RepaintModel")
        try FileManager.default.createDirectory(at: third.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ticket".utf8).write(to: URL(fileURLWithPath: third.path + ".resume"))
        XCTAssertEqual(RepaintModelInstaller(source: .init(archive: packed.url, sha256: packed.sha256), folder: third, required: required).phase, .paused)
    }
}

private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [RepaintModelDownload.Step] = []
    func add(_ step: RepaintModelDownload.Step) { lock.withLock { seen.append(step) } }
    var all: [RepaintModelDownload.Step] { lock.withLock { seen } }
}
