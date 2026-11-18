import Foundation
import Observation
import XCTest
@testable import BraviaKit

/// Stands in for PultProfiles.ProfileImporter: one brand per folder, one profile per file.
final class FakeProfileBuilder: ProfileBuilding, @unchecked Sendable {
    struct Failure: Error {}

    let fingerprint: String
    private let lock = NSLock()
    private var inputs: [ProfileBuildInput] = []
    private var failing = false
    private var extraFile: ProfileFile?
    private var mainThreadBuilds = 0

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    var calls: [ProfileBuildInput] {
        lock.lock()
        defer { lock.unlock() }
        return inputs
    }

    /// Builds that ran on the main thread (there should be none).
    var buildsOnMainThread: Int { lock.withLock { mainThreadBuilds } }

    func fail(_ value: Bool) {
        lock.lock()
        failing = value
        lock.unlock()
    }

    func addOutput(_ file: ProfileFile?) {
        lock.lock()
        extraFile = file
        lock.unlock()
    }

    func build(_ input: ProfileBuildInput) throws -> [ProfileFile] {
        lock.lock()
        inputs.append(input)
        if Thread.isMainThread { mainThreadBuilds += 1 }
        let failing = self.failing
        let extraFile = self.extraFile
        lock.unlock()
        if failing { throw Failure() }
        var brands: [(id: String, name: String, files: [String])] = []
        for file in input.files {
            _ = try file.load()
            let name = file.path.split(separator: "/").count > 1 ? String(file.path.split(separator: "/")[0]) : "Other"
            let id = String(name.lowercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }) .ifEmpty("x")
            if let index = brands.firstIndex(where: { $0.id == id }) {
                brands[index].files.append(file.path)
            } else {
                brands.append((id, name, [file.path]))
            }
        }
        var output: [ProfileFile] = []
        var index: [[String: Any]] = []
        for brand in brands {
            let profiles = brand.files.enumerated().map { offset, path -> [String: Any] in
                ["id": "\(brand.id)-\(offset)", "brand": brand.name, "name": path, "keys": ["power": ["p": "NEC", "a": 4, "c": offset]]]
            }
            output.append(ProfileFile(path: "brands/\(brand.id).json", data: try JSONSerialization.data(withJSONObject: profiles)))
            index.append(["id": brand.id, "name": brand.name, "file": "brands/\(brand.id).json", "profiles": profiles.count])
        }
        var source: [String: Any] = ["db": "Flipper-IRDB", "url": input.url, "commit": input.commit, "license": "CC0-1.0"]
        source["note"] = input.licenseNote
        output.append(ProfileFile(path: "index.json", data: try JSONSerialization.data(withJSONObject: ["schema": 1, "source": source, "brands": index])))
        let power: [[String: Any]] = [["cmd": ["p": "NEC", "a": 4, "c": 0], "brands": brands.map(\.name), "weight": brands.count]]
        output.append(ProfileFile(path: "power_scan.json", data: try JSONSerialization.data(withJSONObject: power)))
        if let extraFile { output.append(extraFile) }
        return output
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

@MainActor
final class StateLog {
    var states: [ProfileDatabase.State] = []
}

@MainActor
final class ProfileDatabaseTests: XCTestCase {
    private var server: FakeGitHub!
    private var directory: URL!

    override func setUp() async throws {
        server = FakeGitHub()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-db-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func files(_ extra: [String: FakeTree.Item] = [:]) -> [String: FakeTree.Item] {
        var files: [String: FakeTree.Item] = [
            "LICENSE": .init(data: cc0License),
            "README.md": .init(data: Data("Commits prior to [2319685](x) are not covered.".utf8)),
            "TVs/LG/LG_42LB.ir": irFile("lg 1"),
            "TVs/LG/LG 32.ir": irFile("lg 2"),
            "TVs/Samsung/BN59.ir": irFile("samsung"),
            "TVs/Samsung/Copy.ir": irFile("samsung"),
            "TVs/Acme": irFile("acme"),
        ]
        for (path, item) in extra { files[path] = item }
        return files
    }

    private func makeDatabase(builder: FakeProfileBuilder = FakeProfileBuilder(fingerprint: "v1"), pinned commit: String? = nil) -> ProfileDatabase {
        let pin = commit.map { PinnedRevision(commit: $0, rootTree: server.tree($0).root, tvsTree: server.tree($0).sha(of: "TVs")!) } ?? .tested
        let client = IRDBClient(transport: server, userAgent: "openpult/1.0", sleep: { _ in }, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        return ProfileDatabase(directory: directory, client: client, builder: builder, now: { Date(timeIntervalSince1970: 1_800_000_000) }, pin: pin)
    }

    private func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    /// Records every state the database goes through.
    private func track(_ database: ProfileDatabase, into log: StateLog) {
        withObservationTracking {
            log.states.append(database.state)
        } onChange: { [weak self] in
            Task { @MainActor in self?.track(database, into: log) }
        }
    }

    private var blobNames: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("source/blobs").path)) ?? [])
    }

    private var buildNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("builds").path)) ?? []).sorted()
    }

    private var rootEntries: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func installedCommit() throws -> String? {
        let data = try Data(contentsOf: directory.appendingPathComponent("current/index.json"))
        let index = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (index?["source"] as? [String: Any])?["commit"] as? String
    }

    // MARK: Install

    func testInstallingThePinnedRevision() async throws {
        let commit = server.add(files())
        let builder = FakeProfileBuilder(fingerprint: "v1")
        let database = makeDatabase(builder: builder, pinned: commit)
        XCTAssertEqual(database.state, .absent)
        XCTAssertNil(database.catalog)

        let outcome = await database.install(.pinned).value
        guard case .installed(let info) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(database.state, .installed(info))
        XCTAssertEqual(database.info, info)
        XCTAssertEqual(database.lastOutcome, outcome)
        XCTAssertFalse(database.isBusy)
        XCTAssertEqual(info.commit, commit)
        XCTAssertEqual(info.tvsTree, server.tree(commit).sha(of: "TVs"))
        XCTAssertEqual(info.importerVersion, "v1")
        XCTAssertEqual(info.counts, .init(files: 5, brands: 3, profiles: 5, powerCodes: 1))
        XCTAssertEqual(info.installedAt, Date(timeIntervalSince1970: 1_800_000_000))

        // The builder got the verified files in os.walk order, with the README's license note.
        let input = try XCTUnwrap(builder.calls.first)
        XCTAssertEqual(input.files.map(\.path), ["Acme", "LG/LG 32.ir", "LG/LG_42LB.ir", "Samsung/BN59.ir", "Samsung/Copy.ir"])
        XCTAssertEqual(try input.files[2].load(), irFile("lg 1").data)
        XCTAssertEqual(input.commit, commit)
        XCTAssertEqual(input.url, "https://github.com/Lucaslhm/Flipper-IRDB")
        XCTAssertEqual(input.licenseNote, IRDBLicense.note(readme: files()["README.md"]!.data))
        XCTAssertEqual(builder.buildsOnMainThread, 0, "the build runs off the main actor")

        let catalog = try XCTUnwrap(database.catalog)
        XCTAssertEqual(try catalog.brands().map(\.name), ["Other", "LG", "Samsung"])
        XCTAssertEqual(try catalog.source()?.commit, commit)
        XCTAssertEqual(try catalog.source()?.note, input.licenseNote)

        // Two API requests (root tree, TVs tree); identical files are downloaded once.
        XCTAssertEqual(server.apiRequests.count, 2)
        XCTAssertEqual(server.rawPaths.sorted(), ["LICENSE", "README.md", "TVs/Acme", "TVs/LG/LG 32.ir", "TVs/LG/LG_42LB.ir", "TVs/Samsung/BN59.ir"])
        XCTAssertEqual(blobNames.count, 6)
        XCTAssertEqual(rootEntries, ["builds", "current", "source"])
        XCTAssertEqual(buildNames.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("current/meta.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("current/manifest.json").path))
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        // Pinned again: nothing to do, no request at all.
        server.reset()
        let again = await database.install(.pinned).value
        XCTAssertEqual(again, .upToDate(info))
        XCTAssertEqual(database.lastOutcome, .upToDate(info))
        XCTAssertEqual(server.requests.count, 0)

        // A fresh start finds the installed database.
        let reopened = makeDatabase(builder: builder, pinned: commit)
        XCTAssertEqual(reopened.state, .installed(info))
        XCTAssertEqual(try reopened.catalog?.brands().count, 3)
        XCTAssertFalse(reopened.isBusy)
    }

    func testPinnedRevisionMustMatchThePinnedTree() async throws {
        let commit = server.add(files())
        let other = server.add(files(["TVs/LG/new.ir": irFile("new")]))
        let client = IRDBClient(transport: server, userAgent: "openpult/1.0", sleep: { _ in })
        func install(_ pin: PinnedRevision) async -> ProfileDatabase.Outcome {
            let database = ProfileDatabase(directory: directory, client: client, builder: FakeProfileBuilder(fingerprint: "v1"), now: { Date() }, pin: pin)
            let outcome = await database.install(.pinned).value
            XCTAssertEqual(database.state, .failed(.integrity(path: outcome == .failed(.integrity(path: "/")) ? "/" : "TVs")))
            database.dismissError()
            XCTAssertEqual(database.state, .absent)
            return outcome
        }
        // TVs/ differs from the pinned tree.
        let wrongTVs = await install(PinnedRevision(commit: commit, rootTree: server.tree(commit).root, tvsTree: server.tree(other).sha(of: "TVs")!))
        XCTAssertEqual(wrongTVs, .failed(.integrity(path: "TVs")))
        // The root differs (e.g. another LICENSE or README), TVs/ is the same.
        let readme = server.add(files(["README.md": .init(data: Data("Commits prior to [abcdef0] are not covered.".utf8))]))
        let wrongRoot = await install(PinnedRevision(commit: readme, rootTree: server.tree(commit).root, tvsTree: server.tree(commit).sha(of: "TVs")!))
        XCTAssertEqual(wrongRoot, .failed(.integrity(path: "/")))
        XCTAssertEqual(server.rawPaths, [])
    }

    func testLatestUsesTheETagAndDownloadsOnlyChangedFiles() async throws {
        let first = server.add(files())
        let database = makeDatabase()
        let outcome = await database.install(.latest).value
        guard case .installed(let info) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(info.commit, first)
        XCTAssertEqual(server.apiRequests.count, 3)
        XCTAssertFalse(info.isPinned)

        // main has not moved: one conditional request, answered with 304.
        server.reset()
        let unchanged = await database.install(.latest).value
        XCTAssertEqual(unchanged, .upToDate(info))
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertNotNil(server.requests.first?.value(forHTTPHeaderField: "If-None-Match"))

        // A new commit that leaves TVs/ alone: already up to date after the root tree.
        server.add(files(["README.md": .init(data: Data("new readme".utf8))]))
        server.reset()
        let sameTree = await database.install(.latest).value
        XCTAssertEqual(sameTree, .upToDate(info))
        XCTAssertEqual(server.apiRequests.count, 2)
        XCTAssertEqual(server.rawPaths, [])
        // Checked again: main is where it was and its tree is known, one free request.
        server.reset()
        let again = await database.install(.latest).value
        XCTAssertEqual(again, .upToDate(info))
        XCTAssertEqual(server.requests.count, 1)

        // One changed and one new file: only those are downloaded; old blobs are dropped.
        let third = server.add(files(["TVs/LG/LG_42LB.ir": irFile("lg 1 fixed"), "TVs/Sony/KD.ir": irFile("sony")]))
        server.reset()
        let updated = await database.install(.latest).value
        guard case .installed(let newInfo) = updated else { return XCTFail("\(updated)") }
        XCTAssertEqual(newInfo.commit, third)
        XCTAssertEqual(server.rawPaths.sorted(), ["TVs/LG/LG_42LB.ir", "TVs/Sony/KD.ir"])
        XCTAssertEqual(try installedCommit(), third)
        XCTAssertFalse(blobNames.contains(GitObjectHash.blob(irFile("lg 1").data)))
        XCTAssertTrue(blobNames.contains(GitObjectHash.blob(irFile("lg 1 fixed").data)))
        XCTAssertEqual(try database.catalog?.brands().map(\.name), ["Other", "LG", "Samsung", "Sony"])
    }

    // MARK: Interruptions

    func testCancelKeepsTheDownloadedFilesForResume() async throws {
        var extra: [String: FakeTree.Item] = [:]
        for index in 0..<30 { extra["TVs/Bulk/\(index).ir"] = irFile("bulk \(index)") }
        let commit = server.add(files(extra))
        let database = makeDatabase(pinned: commit)
        server.latency = 5_000_000
        let seen = Counter()
        server.setOnRequest { request in
            guard request.url?.path.contains("/TVs/") == true else { return }
            if seen.next() == 10 { Task { @MainActor in database.cancel() } }
        }
        let outcome = await database.install(.pinned).value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(database.state, .absent)
        XCTAssertNil(database.catalog)
        XCTAssertFalse(database.isBusy)
        let kept = blobNames
        XCTAssertGreaterThan(kept.count, 2, "LICENSE, README and some files stay")
        XCTAssertLessThan(kept.count, 36)

        server.setOnRequest(nil)
        server.reset()
        let resumed = await database.install(.pinned).value
        guard case .installed = resumed else { return XCTFail("\(resumed)") }
        let downloadedAgain = Set(server.rawPaths.map { GitObjectHash.blob(files(extra)[$0]!.data) })
        XCTAssertTrue(downloadedAgain.isDisjoint(with: kept), "kept files are not downloaded again")
        XCTAssertEqual(blobNames.count, 36, "34 distinct files, LICENSE, README")
    }

    func testFailedDownloadResumesAndKeepsTheInstalledDatabase() async throws {
        let first = server.add(files())
        let database = makeDatabase()
        guard case .installed(let info) = await database.install(.latest).value else { return XCTFail() }

        var extra: [String: FakeTree.Item] = [:]
        for index in 0..<12 { extra["TVs/Bulk/\(index).ir"] = irFile("bulk \(index)") }
        let second = server.add(files(extra))
        server.setHook { request in
            request.url?.path.hasSuffix("/Bulk/7.ir") == true ? MockResponse(status: 404) : nil
        }
        let failed = await database.install(.latest).value
        XCTAssertEqual(failed, .failed(.notFound))
        XCTAssertEqual(database.state, .failed(.notFound))
        XCTAssertEqual(database.info, info, "the installed database stays")
        XCTAssertEqual(try database.catalog?.source()?.commit, first)
        XCTAssertEqual(try installedCommit(), first)

        server.setHook(nil)
        server.reset()
        let resumed = await database.install(.latest).value
        guard case .installed(let newInfo) = resumed else { return XCTFail("\(resumed)") }
        XCTAssertEqual(newInfo.commit, second)
        XCTAssertTrue(server.rawPaths.contains("TVs/Bulk/7.ir"))
        XCTAssertLessThan(server.rawPaths.count, 12, "files from the failed attempt are kept")
    }

    func testBuildErrorRollsBack() async throws {
        let first = server.add(files())
        let builder = FakeProfileBuilder(fingerprint: "v1")
        let database = makeDatabase(builder: builder)
        guard case .installed(let info) = await database.install(.latest).value else { return XCTFail() }
        let catalog = database.catalog

        let second = server.add(files(["TVs/Sony/KD.ir": irFile("sony")]))
        builder.fail(true)
        let outcome = await database.install(.latest).value
        guard case .failed(.buildFailed) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(database.info, info)
        XCTAssertTrue(database.catalog === catalog)
        XCTAssertEqual(try installedCommit(), first)
        XCTAssertEqual(rootEntries, ["builds", "current", "source"], "no incoming build is left behind")
        XCTAssertEqual(buildNames.count, 1)

        // Output the database does not expect is refused as well.
        builder.fail(false)
        builder.addOutput(ProfileFile(path: "../escape.json", data: Data("[]".utf8)))
        let refused = await database.install(.latest).value
        guard case .failed(.buildFailed) = refused else { return XCTFail("\(refused)") }
        XCTAssertEqual(try installedCommit(), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escape.json").path))

        // Names that differ only in case would be one file on the device.
        builder.addOutput(ProfileFile(path: "brands/LG.json", data: Data("[]".utf8)))
        let folded = await database.install(.latest).value
        guard case .failed(.buildFailed) = folded else { return XCTFail("\(folded)") }
        XCTAssertEqual(ProfileDatabaseError.buildFailed("brands/\u{202E}x").errorDescription, ProfileDatabaseError.buildFailed("").errorDescription,
                       "names from the database are not shown")

        builder.addOutput(nil)
        let fixed = await database.install(.latest).value
        guard case .installed(let newInfo) = fixed else { return XCTFail("\(fixed)") }
        XCTAssertEqual(newInfo.commit, second)
        XCTAssertFalse(database.catalog === catalog, "a new catalog for the new files")
        XCTAssertEqual(rootEntries, ["builds", "current", "source"])
        XCTAssertEqual(buildNames.count, 2, "the previous build stays for catalogs still in use")
    }

    func testLicenseIsCheckedBeforeAnyFile() async throws {
        server.add(files(["LICENSE": .init(data: Data("MIT License\n\nPermission is hereby granted".utf8))]))
        let database = makeDatabase()
        let outcome = await database.install(.latest).value
        XCTAssertEqual(outcome, .failed(.licenseRejected))
        XCTAssertEqual(server.rawPaths, ["LICENSE"])
        XCTAssertNotNil(ProfileDatabaseError.licenseRejected.errorDescription)
    }

    func testRateLimitSurfacesAsState() async throws {
        server.add(files())
        server.setHook { request in
            request.url?.host == "api.github.com"
                ? MockResponse(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800001800"])
                : nil
        }
        let database = makeDatabase()
        let outcome = await database.install(.latest).value
        XCTAssertEqual(outcome, .failed(.rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_001_800))))
        XCTAssertEqual(server.requests.count, 1)
    }

    func testInstallRightAfterCancelStartsAnew() async throws {
        var extra: [String: FakeTree.Item] = [:]
        for index in 0..<30 { extra["TVs/Bulk/\(index).ir"] = irFile("bulk \(index)") }
        let commit = server.add(files(extra))
        let database = makeDatabase(pinned: commit)
        server.latency = 5_000_000
        let first = database.install(.pinned)
        let started = await waitUntil { self.blobNames.count > 3 }
        XCTAssertTrue(started)
        database.cancel()
        let second = database.install(.pinned)
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .cancelled)
        guard case .installed = secondOutcome else { return XCTFail("\(secondOutcome)") }
        XCTAssertEqual(database.lastOutcome, secondOutcome)
        XCTAssertFalse(database.isBusy)
    }

    func testAnOldCatalogKeepsReadingItsOwnVersion() async throws {
        server.add(files())
        let database = makeDatabase()
        guard case .installed = await database.install(.latest).value else { return XCTFail() }
        let old = try XCTUnwrap(database.catalog)
        let oldBrands = try old.brands()

        server.add(files(["TVs/LG/Extra 1.ir": irFile("extra 1"), "TVs/LG/Extra 2.ir": irFile("extra 2")]))
        guard case .installed = await database.install(.latest).value else { return XCTFail() }
        let lg = try XCTUnwrap(oldBrands.first { $0.name == "LG" })
        XCTAssertEqual(try old.profiles(for: lg).count, lg.profiles, "the index and the brand files of one build")
        XCTAssertEqual(try database.catalog?.profiles(for: XCTUnwrap(database.catalog?.brand(named: "LG"))).count, 4)

        // Superseded builds go at the next start.
        XCTAssertEqual(buildNames.count, 2)
        _ = makeDatabase()
        XCTAssertEqual(buildNames.count, 1)
    }

    func testRebuildKeepsTheFilesOfAnInterruptedDownload() async throws {
        let first = server.add(files())
        let database = makeDatabase(builder: FakeProfileBuilder(fingerprint: "v1"))
        guard case .installed = await database.install(.latest).value else { return XCTFail() }
        _ = first

        var extra: [String: FakeTree.Item] = [:]
        for index in 0..<12 { extra["TVs/Bulk/\(index).ir"] = irFile("bulk \(index)") }
        server.add(files(extra))
        server.setHook { request in request.url?.path.hasSuffix("/Bulk/7.ir") == true ? MockResponse(status: 404) : nil }
        _ = await database.install(.latest).value
        let pending = blobNames
        XCTAssertGreaterThan(pending.count, 6)

        // The app was updated: a new importer rebuilds the installed revision offline.
        let reopened = makeDatabase(builder: FakeProfileBuilder(fingerprint: "v2"))
        await reopened.waitUntilIdle()
        guard case .installed = reopened.state else { return XCTFail("\(reopened.state)") }
        XCTAssertEqual(blobNames, pending, "the interrupted download can still resume")
    }

    func testValidMetaWithoutManifestCannotRebuild() async throws {
        let commit = server.add(files())
        let database = makeDatabase(pinned: commit)
        guard case .installed = await database.install(.pinned).value else { return XCTFail() }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("current/manifest.json"))
        let reopened = makeDatabase(builder: FakeProfileBuilder(fingerprint: "v2"), pinned: commit)
        await reopened.waitUntilIdle()
        XCTAssertEqual(reopened.state, .failed(.sourceMissing))
        XCTAssertNotNil(reopened.catalog)
    }

    // MARK: Storage

    func testRemoveDeletesEverything() async throws {
        let commit = server.add(files())
        let database = makeDatabase(pinned: commit)
        guard case .installed = await database.install(.pinned).value else { return XCTFail() }
        let removed = await database.remove().value
        XCTAssertEqual(removed, .removed)
        XCTAssertEqual(database.state, .absent)
        XCTAssertNil(database.info)
        XCTAssertNil(database.catalog)
        XCTAssertEqual(rootEntries, [])
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(makeDatabase(pinned: commit).state, .absent)
    }

    func testRemoveDuringADownloadCancelsIt() async throws {
        var extra: [String: FakeTree.Item] = [:]
        for index in 0..<30 { extra["TVs/Bulk/\(index).ir"] = irFile("bulk \(index)") }
        let commit = server.add(files(extra))
        let database = makeDatabase(pinned: commit)
        server.latency = 20_000_000
        let install = database.install(.pinned)
        let started = await waitUntil { self.blobNames.count > 3 }
        XCTAssertTrue(started)
        let removal = database.remove()
        XCTAssertEqual(database.state, .removing)
        XCTAssertTrue(database.install(.pinned) == removal, "an install during the removal is the removal")
        let removed = await removal.value
        let installOutcome = await install.value
        XCTAssertEqual(installOutcome, .cancelled)
        XCTAssertEqual(removed, .removed)
        XCTAssertEqual(database.state, .absent)
        XCTAssertFalse(database.isBusy)
        XCTAssertEqual(rootEntries, [])
    }

    func testImporterChangeRebuildsOffline() async throws {
        let commit = server.add(files())
        let database = makeDatabase(builder: FakeProfileBuilder(fingerprint: "v1"), pinned: commit)
        guard case .installed(let old) = await database.install(.pinned).value else { return XCTFail() }

        server.reset()
        let builder = FakeProfileBuilder(fingerprint: "v2")
        let reopened = makeDatabase(builder: builder, pinned: commit)
        XCTAssertTrue(reopened.isBusy, "the rebuild starts right away")
        XCTAssertEqual(reopened.info, old, "the old build stays usable meanwhile")
        XCTAssertNotNil(reopened.catalog)
        await reopened.waitUntilIdle()
        guard case .installed(let info) = reopened.state else { return XCTFail("\(reopened.state)") }
        XCTAssertEqual(info.importerVersion, "v2")
        XCTAssertEqual(info.commit, commit)
        XCTAssertEqual(builder.calls.count, 1)
        XCTAssertEqual(server.requests.count, 0, "no network")

        // A manifest that does not belong to the installed build is not used.
        let manifestURL = directory.appendingPathComponent("current/manifest.json")
        let manifest = try Data(contentsOf: manifestURL)
        try Data(String(decoding: manifest, as: UTF8.self).replacingOccurrences(of: commit, with: String(repeating: "e", count: 40)).utf8).write(to: manifestURL)
        let mismatched = makeDatabase(builder: FakeProfileBuilder(fingerprint: "v9"), pinned: commit)
        await mismatched.waitUntilIdle()
        XCTAssertEqual(mismatched.state, .failed(.sourceMissing))
        try manifest.write(to: manifestURL)

        // Without the downloaded files the rebuild reports what is missing; the old build stays.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("source/blobs"))
        let third = makeDatabase(builder: FakeProfileBuilder(fingerprint: "v3"), pinned: commit)
        await third.waitUntilIdle()
        XCTAssertEqual(third.state, .failed(.sourceMissing))
        XCTAssertEqual(third.info, info)
        XCTAssertEqual(try third.catalog?.brands().count, 3)

        // Built by the current importer: nothing to rebuild, nothing to download.
        let fourth = makeDatabase(builder: FakeProfileBuilder(fingerprint: "v2"), pinned: commit)
        XCTAssertFalse(fourth.isBusy)
        let rebuilt = await fourth.install(.pinned).value
        XCTAssertEqual(rebuilt, .upToDate(info))
    }

    func testDamagedBlobsAreDownloadedAgain() async throws {
        let commit = server.add(files())
        let database = makeDatabase(pinned: commit)
        guard case .installed = await database.install(.pinned).value else { return XCTFail() }
        let sha = GitObjectHash.blob(irFile("lg 1").data)
        try Data("damaged".utf8).write(to: directory.appendingPathComponent("source/blobs/\(sha)"))

        server.reset()
        let builder = FakeProfileBuilder(fingerprint: "v2")
        let reopened = makeDatabase(builder: builder, pinned: commit)
        await reopened.waitUntilIdle()
        XCTAssertEqual(reopened.state, .failed(.sourceMissing))
        XCTAssertFalse(blobNames.contains(sha), "the damaged file is deleted")

        let repaired = await reopened.install(.pinned).value
        guard case .installed(let info) = repaired else { return XCTFail("\(repaired)") }
        XCTAssertEqual(info.importerVersion, "v2")
        XCTAssertEqual(server.rawPaths, ["TVs/LG/LG_42LB.ir"])
    }

    func testInterruptedBuildsAreRemovedOnOpen() throws {
        let orphan = directory.appendingPathComponent("incoming-\(UUID().uuidString)/brands", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: orphan.appendingPathComponent("x.json"))
        let database = makeDatabase()
        XCTAssertEqual(database.state, .absent)
        XCTAssertEqual(rootEntries, [])
    }

    func testCorruptMetaIsIgnored() throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("current"), withIntermediateDirectories: true)
        try Data("{\"commit\":1}".utf8).write(to: directory.appendingPathComponent("current/meta.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("current/index.json"))
        let database = makeDatabase()
        XCTAssertEqual(database.state, .absent)
        XCTAssertNil(database.catalog)
    }

    func testOutputPathsAreChecked() {
        for good in ["index.json", "power_scan.json", "brands/lg.json", "brands/a-b_c.2.json"] {
            XCTAssertTrue(ProfileDatabaseStorage.isOutputPath(good), good)
        }
        for bad in ["meta.json", "brands/../x.json", "../index.json", "/index.json", "brands/.json", "brands/.x.json",
                    "brands/a/b.json", "brands/\u{C4}.json", "brands/a.txt", "other/a.json", "brands/a b.json", "LICENSE"] {
            XCTAssertFalse(ProfileDatabaseStorage.isOutputPath(bad), bad)
        }
    }

    // MARK: Progress

    func testProgressGoesThroughThePhases() async throws {
        var extra: [String: FakeTree.Item] = [:]
        for index in 0..<20 { extra["TVs/Bulk/\(index).ir"] = irFile("bulk \(index)") }
        let commit = server.add(files(extra))
        let database = makeDatabase(pinned: commit)
        server.latency = 2_000_000
        let log = StateLog()
        track(database, into: log)
        _ = await database.install(.pinned).value
        let finished = await waitUntil { if case .installed = log.states.last { return true } else { return false } }
        XCTAssertTrue(finished)
        let states = log.states
        let downloads = states.compactMap { state -> ProfileDatabase.Progress? in
            if case .downloading(let progress) = state { return progress }
            return nil
        }
        XCTAssertEqual(downloads.first?.phase, .manifest)
        let files = downloads.filter { $0.phase == .files }
        XCTAssertFalse(files.isEmpty)
        XCTAssertEqual(files.last?.totalFiles, 24)
        XCTAssertEqual(files.map(\.completedBytes), files.map(\.completedBytes).sorted(), "never steps back")
        XCTAssertTrue(states.contains(.building))
        guard case .installed = states.last else { return XCTFail("\(states)") }
        XCTAssertEqual(ProfileDatabase.Progress(phase: .files, completedBytes: 5, totalBytes: 10).fraction, 0.5)
    }
}
