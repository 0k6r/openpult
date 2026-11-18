import Foundation
import Observation
import PultProfiles

// MARK: - Errors

public enum ProfileDatabaseError: Error, Equatable, Sendable {
    /// No internet connection.
    case offline
    /// Timeouts or dropped connections, also after the retries.
    case network
    /// The GitHub API limit for this IP address is used up (60 requests an hour without an account).
    case rateLimited(resetAt: Date?)
    /// An HTTP status the app does not expect.
    case server(status: Int)
    case notFound
    /// A malformed answer: bad JSON, a truncated or inconsistent file list, an unsafe path, an unknown file mode.
    case invalidResponse
    /// More files or bytes than the limits in `IRDBLimits`.
    case tooLarge
    /// A file or a folder listing does not match its git SHA-1.
    case integrity(path: String)
    /// `LICENSE` is not the CC0 1.0 legal code: the import needs a human review first.
    case licenseRejected
    /// The downloaded files needed for an offline rebuild are gone or damaged.
    case sourceMissing
    case buildFailed(String)
    case storage(String)
}

extension ProfileDatabaseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .offline:
            return String(localized: "No internet connection. Connect to the internet and try again.", bundle: .module)
        case .network:
            return String(localized: "GitHub is not responding. Check the internet connection and try again.", bundle: .module)
        case .rateLimited(let resetAt):
            guard let resetAt else {
                return String(localized: "GitHub's download limit has been reached. Try again in an hour.", bundle: .module)
            }
            let time = resetAt.formatted(date: .omitted, time: .shortened)
            return String(localized: "GitHub's download limit has been reached. Try again after \(time).", bundle: .module)
        case .server(let status):
            return String(localized: "GitHub returned an error (\(status)). Try again later.", bundle: .module)
        case .notFound:
            return String(localized: "The TV code database was not found on GitHub.", bundle: .module)
        case .invalidResponse:
            return String(localized: "GitHub sent an unexpected file list. The download was stopped.", bundle: .module)
        case .tooLarge:
            return String(localized: "The TV code database is larger than expected. The download was stopped.", bundle: .module)
        case .integrity:
            return String(localized: "A downloaded file did not match its checksum. Try again later.", bundle: .module)
        case .licenseRejected:
            return String(localized: "The license of the TV code database has changed and needs a review. The download was stopped.", bundle: .module)
        case .sourceMissing:
            return String(localized: "Some downloaded files are missing. Download the database again.", bundle: .module)
        case .buildFailed:
            // The detail may quote names from the database: kept for diagnostics, not shown.
            return String(localized: "Could not build the TV profiles from the downloaded files.", bundle: .module)
        case .storage(let detail):
            return String(localized: "Could not save the TV code database: \(detail)", bundle: .module)
        }
    }
}

// MARK: - Builder

/// One output file of the importer, relative to the database folder ("index.json", "brands/lg.json", ...).
public struct ProfileFile: Equatable, Sendable {
    public let path: String
    public let data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

/// What the importer gets: the verified files of `TVs/` and where they come from.
public struct ProfileBuildInput: Sendable {
    public struct File: Sendable {
        /// Relative to `TVs/`.
        public let path: String
        public let load: @Sendable () throws -> Data

        public init(path: String, load: @escaping @Sendable () throws -> Data) {
            self.path = path
            self.load = load
        }
    }

    /// In `os.walk` order, like the Python importer reads a checkout.
    public let files: [File]
    public let commit: String
    public let url: String
    public let licenseNote: String?

    public init(files: [File], commit: String, url: String, licenseNote: String?) {
        self.files = files
        self.commit = commit
        self.url = url
        self.licenseNote = licenseNote
    }
}

/// Turns Flipper-IRDB files into profiles (index.json, brands/*.json, power_scan.json; see profiles/SCHEMA.md).
public protocol ProfileBuilding: Sendable {
    /// Changes whenever the same input gives a different output (importer version, key aliases).
    /// A database built with another fingerprint is rebuilt from the downloaded files.
    var fingerprint: String { get }
    func build(_ input: ProfileBuildInput) throws -> [ProfileFile]
}

/// The production builder: `PultProfiles.ProfileImporter` with the bundled key aliases.
public struct PultProfileBuilder: ProfileBuilding {
    public init() {}

    public var fingerprint: String { ProfileImporter.fingerprint(aliases: .bundled) }

    public func build(_ input: ProfileBuildInput) throws -> [ProfileFile] {
        let bundle = try ProfileImporter.run(
            files: input.files.map { IRDBFile(path: $0.path, load: $0.load) },
            aliases: .bundled,
            source: ImportSource(commit: input.commit, url: input.url, licenseNote: input.licenseNote)
        )
        return bundle.files.map { ProfileFile(path: $0.path, data: $0.data) }
    }
}

// MARK: - Database

/// The TV code database on this device: downloaded from Flipper-IRDB on the user's request and built into
/// profiles locally (the database is not shipped with the app).
///
/// Layout below `directory` (Application Support, excluded from backups):
/// `current` a symlink to the build in use, `builds/<uuid>/` (index.json, brands/, power_scan.json, plus meta.json and
/// manifest.json, the verified file list it was built from); `source/blobs/` the downloaded files by blob SHA, kept for
/// updates and offline rebuilds, plus `source/latest.json` (the ETag of `main`); `incoming-<uuid>/` a build being
/// written. A build never changes once `current` points to it, so a `ProfileCatalog` still in use after an update
/// keeps reading one consistent version.
///
/// Create one instance per folder (one for the app): operations are serialized within an instance only.
@MainActor
@Observable
public final class ProfileDatabase {
    public enum Revision: Equatable, Sendable {
        /// The commit this app version was tested with (`IRDBPin`).
        case pinned
        /// Whatever `main` points to now.
        case latest
    }

    public struct Info: Codable, Equatable, Sendable {
        public struct Counts: Codable, Equatable, Sendable {
            /// Files of `TVs/` the profiles were built from.
            public let files: Int
            public let brands: Int
            public let profiles: Int
            public let powerCodes: Int
        }

        public let commit: String
        public let tvsTree: String
        public let installedAt: Date
        /// The builder's fingerprint.
        public let importerVersion: String
        public let counts: Counts

        public var isPinned: Bool { commit == IRDBPin.commit }
        /// Known for the pinned commit only.
        public var commitDate: Date? { isPinned ? IRDBPin.date : nil }
    }

    public struct Progress: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            /// The commit and the file list (two or three small API requests).
            case manifest
            /// The files, counted by bytes; files kept from an interrupted download count as done.
            case files
        }

        public var phase: Phase
        public var completedFiles = 0
        public var totalFiles = 0
        public var completedBytes = 0
        public var totalBytes = 0

        public var fraction: Double {
            totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
        }
    }

    public enum State: Equatable, Sendable {
        case absent
        case installed(Info)
        case downloading(Progress)
        /// Building the profiles from the downloaded files.
        case building
        /// Deleting the database (after stopping a running operation).
        case removing
        /// The last operation failed; `info` and `catalog` still describe what is installed.
        case failed(ProfileDatabaseError)
    }

    public enum Outcome: Equatable, Sendable {
        case installed(Info)
        /// Nothing to do: the same files were already installed with the same importer.
        case upToDate(Info)
        case removed
        case cancelled
        case failed(ProfileDatabaseError)
    }

    public private(set) var state: State = .absent
    /// The installed database, also while an update runs or after it failed.
    public private(set) var info: Info? = nil
    /// `nil` until a database is installed.
    public private(set) var catalog: ProfileCatalog? = nil
    /// How the last operation ended (e.g. to tell the user the database was already up to date).
    public private(set) var lastOutcome: Outcome? = nil
    public private(set) var isBusy = false

    @ObservationIgnored private let storage: ProfileDatabaseStorage
    @ObservationIgnored private let client: IRDBClient
    @ObservationIgnored private let builder: any ProfileBuilding
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let pin: PinnedRevision
    @ObservationIgnored private var operation: Task<Outcome, Never>?
    @ObservationIgnored private var generation = 0

    public nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("ProfileDatabase", isDirectory: true)
    }

    /// Opens the database at `directory`: removes interrupted builds and loads what is installed. If it was built
    /// by another importer version, a rebuild from the downloaded files starts right away (no network).
    public convenience init(
        directory: URL = ProfileDatabase.defaultDirectory,
        client: IRDBClient = IRDBClient(),
        builder: any ProfileBuilding = PultProfileBuilder(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(directory: directory, client: client, builder: builder, now: now, pin: .tested)
    }

    init(
        directory: URL,
        client: IRDBClient,
        builder: any ProfileBuilding,
        now: @escaping @Sendable () -> Date,
        pin: PinnedRevision
    ) {
        storage = ProfileDatabaseStorage(root: directory)
        self.client = client
        self.builder = builder
        self.now = now
        self.pin = pin
        do {
            let (installed, build) = try storage.open()
            info = installed
            catalog = build.map { ProfileCatalog(directory: $0) }
            state = installed.map(State.installed) ?? .absent
        } catch {
            state = .failed(.storage(error.localizedDescription))
        }
        if let info, info.importerVersion != builder.fingerprint {
            rebuild()
        }
    }

    /// Downloads and installs a revision. Requests go out only from here. While another operation runs,
    /// that operation is returned instead; after `cancel()` a new one starts once the cancelled one has stopped.
    @discardableResult
    public func install(_ revision: Revision) -> Task<Outcome, Never> {
        if let operation, !operation.isCancelled { return operation }
        return start(.downloading(Progress(phase: .manifest)), after: operation) { try await $0.install(revision) }
    }

    /// Rebuilds the installed revision from the downloaded files, without the network.
    @discardableResult
    public func rebuild() -> Task<Outcome, Never> {
        if let operation, !operation.isCancelled { return operation }
        return start(.building, after: operation) { try await $0.rebuild() }
    }

    /// Stops a download; the files downloaded so far are kept, so the next install continues from there.
    public func cancel() {
        operation?.cancel()
    }

    /// Deletes the database and the downloaded files. A running operation is cancelled first.
    @discardableResult
    public func remove() -> Task<Outcome, Never> {
        let previous = operation
        previous?.cancel()
        return start(.removing, after: previous) { try await $0.remove() }
    }

    public func dismissError() {
        if case .failed = state, !isBusy { state = info.map(State.installed) ?? .absent }
    }

    /// Waits for the running operation and any queued after it (tests, previews). It does not return early when
    /// the waiting task is cancelled; use `cancel()` to stop the operation itself.
    public func waitUntilIdle() async {
        while let operation { _ = await operation.value }
    }

    // MARK: Operations

    private func start(
        _ initial: State,
        after previous: Task<Outcome, Never>? = nil,
        _ body: @escaping @Sendable (ProfileDatabaseWorker) async throws -> ProfileDatabaseWorker.Result
    ) -> Task<Outcome, Never> {
        generation += 1
        let id = generation
        isBusy = true
        lastOutcome = nil
        state = initial
        let task = Task { () -> Outcome in
            _ = await previous?.value
            return await self.run(id, body)
        }
        operation = task
        return task
    }

    private func run(
        _ id: Int,
        _ body: @Sendable (ProfileDatabaseWorker) async throws -> ProfileDatabaseWorker.Result
    ) async -> Outcome {
        let worker = ProfileDatabaseWorker(
            storage: storage,
            client: client,
            builder: builder,
            now: now,
            pin: pin,
            installed: info,
            report: { [weak self] event in await self?.apply(event, id: id) }
        )
        let outcome: Outcome
        do {
            switch try await body(worker) {
            case .installed(let installed, let build):
                info = installed
                catalog = ProfileCatalog(directory: build)
                outcome = .installed(installed)
            case .upToDate:
                outcome = info.map(Outcome.upToDate) ?? .failed(.sourceMissing)
            case .removed:
                info = nil
                catalog = nil
                outcome = .removed
            }
        } catch is CancellationError {
            outcome = .cancelled
        } catch let error as ProfileDatabaseError {
            outcome = .failed(error)
        } catch {
            outcome = .failed(.storage(error.localizedDescription))
        }
        guard id == generation else { return outcome }
        operation = nil
        isBusy = false
        lastOutcome = outcome
        if case .failed(let error) = outcome {
            state = .failed(error)
        } else {
            state = info.map(State.installed) ?? .absent
        }
        return outcome
    }

    private func apply(_ event: ProfileDatabaseWorker.Event, id: Int) {
        guard id == generation, isBusy else { return }
        switch event {
        case .progress(let progress):
            // Files finish in parallel and their reports may arrive out of order: never step back.
            if case .downloading(let shown) = state, shown.phase == progress.phase, shown.completedFiles > progress.completedFiles {
                return
            }
            state = .downloading(progress)
        case .building:
            state = .building
        }
    }
}

// MARK: - Worker

/// The revision `.pinned` installs; tests pin their own fake repository.
struct PinnedRevision: Equatable, Sendable {
    let commit: String
    let rootTree: String
    let tvsTree: String

    static let tested = PinnedRevision(commit: IRDBPin.commit, rootTree: IRDBPin.rootTree, tvsTree: IRDBPin.tvsTree)
}

/// Runs an operation off the main actor (`@concurrent`, also under nonisolated(nonsending) defaults).
struct ProfileDatabaseWorker: Sendable {
    enum Event: Sendable {
        case progress(ProfileDatabase.Progress)
        case building
    }

    enum Result: Sendable {
        /// The new build's folder.
        case installed(ProfileDatabase.Info, URL)
        case upToDate
        case removed
    }

    let storage: ProfileDatabaseStorage
    let client: IRDBClient
    let builder: any ProfileBuilding
    let now: @Sendable () -> Date
    let pin: PinnedRevision
    let installed: ProfileDatabase.Info?
    let report: @Sendable (Event) async -> Void

    @concurrent
    func install(_ revision: ProfileDatabase.Revision) async throws -> Result {
        let fingerprint = builder.fingerprint
        let commit: String
        var latest: ProfileDatabaseStorage.LatestCache?
        switch revision {
        case .pinned:
            commit = pin.commit
        case .latest:
            let cache = try await latestCommit()
            latest = cache
            commit = cache.commit
        }
        let current = installed.map { $0.importerVersion == fingerprint } == true ? installed : nil
        if let current, current.commit == commit || current.tvsTree == latest?.tvsTree {
            return .upToDate
        }

        let root = try await client.root(commit: commit)
        if revision == .pinned {
            guard root.tree == pin.rootTree else { throw ProfileDatabaseError.integrity(path: "/") }
            guard root.tvs == pin.tvsTree else { throw ProfileDatabaseError.integrity(path: "TVs") }
        }
        if let latest {
            // Remembered for the next check: an unchanged main then costs one request that GitHub does not count.
            storage.saveLatest(.init(etag: latest.etag, commit: commit, tvsTree: root.tvs))
        }
        if let current, current.tvsTree == root.tvs {
            return .upToDate
        }
        guard let license = root.license, license.size <= IRDBLimits.maxLicenseBytes else {
            throw ProfileDatabaseError.licenseRejected
        }
        let manifest = try await client.manifest(tree: root.tvs)
        let snapshot = ProfileDatabaseStorage.Snapshot(commit: commit, root: root, manifest: manifest)
        try storage.prepareSource()

        // LICENSE first: nothing else is downloaded under a license nobody has reviewed.
        let licenseText = try await fetch(.init(path: "LICENSE", sha: license.sha, size: license.size), commit: commit)
        guard IRDBLicense.isCC0(licenseText) else { throw ProfileDatabaseError.licenseRejected }
        if let readme = root.readme, readme.size <= IRDBLimits.maxReadmeBytes {
            _ = try await fetch(.init(path: "README.md", sha: readme.sha, size: readme.size), commit: commit)
        }

        // Identical files share one blob: count and download each blob once.
        var seen = Set<String>()
        var missing: [IRDBClient.FileRequest] = []
        var progress = ProfileDatabase.Progress(phase: .files)
        for file in manifest.files where seen.insert(file.sha).inserted {
            progress.totalFiles += 1
            progress.totalBytes += file.size
            if storage.hasBlob(file.sha, size: file.size) {
                progress.completedFiles += 1
                progress.completedBytes += file.size
            } else {
                missing.append(.init(path: "TVs/\(file.path)", sha: file.sha, size: file.size))
            }
        }
        await report(.progress(progress))
        let counter = ProgressCounter(progress)
        try await client.download(missing, commit: commit) { file, data in
            try storage.writeBlob(data, sha: file.sha)
            await report(.progress(counter.add(bytes: file.size)))
        }
        return try await build(snapshot, collectGarbage: true)
    }

    @concurrent
    func rebuild() async throws -> Result {
        guard let snapshot = storage.loadSnapshot(), let installed,
              snapshot.commit == installed.commit, snapshot.manifest.tree == installed.tvsTree else {
            throw ProfileDatabaseError.sourceMissing
        }
        // Blobs of an interrupted download stay for its resume.
        return try await build(snapshot, collectGarbage: false)
    }

    @concurrent
    func remove() async throws -> Result {
        try storage.removeAll()
        return .removed
    }

    /// The commit of `main`, with its TVs tree when an earlier check already learned it.
    private func latestCommit() async throws -> ProfileDatabaseStorage.LatestCache {
        let cached = storage.loadLatest()
        switch try await client.latestCommit(etag: cached?.etag) {
        case .unchanged:
            guard let cached else { throw ProfileDatabaseError.invalidResponse }
            return cached
        case .commit(let sha, let etag):
            let cache = ProfileDatabaseStorage.LatestCache(etag: etag, commit: sha, tvsTree: nil)
            storage.saveLatest(cache)
            return cache
        }
    }

    /// A blob from the store, or from GitHub when it is not there yet.
    private func fetch(_ file: IRDBClient.FileRequest, commit: String) async throws -> Data {
        if let data = try? storage.readBlob(file.sha, size: file.size) { return data }
        let data = try await client.file(file, commit: commit)
        try storage.writeBlob(data, sha: file.sha)
        return data
    }

    private func build(_ snapshot: ProfileDatabaseStorage.Snapshot, collectGarbage: Bool) async throws -> Result {
        try Task.checkCancellation()
        await report(.building)
        guard let license = snapshot.root.license,
              let licenseText = try? storage.readBlob(license.sha, size: license.size) else {
            throw ProfileDatabaseError.sourceMissing
        }
        guard IRDBLicense.isCC0(licenseText) else { throw ProfileDatabaseError.licenseRejected }
        let readme = snapshot.root.readme.flatMap { try? storage.readBlob($0.sha, size: $0.size) }
        for file in snapshot.manifest.files where !storage.hasBlob(file.sha, size: file.size) {
            throw ProfileDatabaseError.sourceMissing
        }
        let storage = self.storage
        // The importer skips files it cannot read; here that would silently drop codes.
        let unreadable = Flag()
        let input = ProfileBuildInput(
            files: snapshot.manifest.files.map { file in
                ProfileBuildInput.File(path: file.path) {
                    do {
                        return try storage.readBlob(file.sha, size: file.size)
                    } catch {
                        unreadable.set()
                        throw error
                    }
                }
            },
            commit: snapshot.commit,
            url: IRDBPin.url,
            licenseNote: IRDBLicense.note(readme: readme)
        )
        let output: [ProfileFile]
        do {
            output = try builder.build(input)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProfileDatabaseError {
            throw error
        } catch {
            throw ProfileDatabaseError.buildFailed(String(describing: error))
        }
        if unreadable.isSet { throw ProfileDatabaseError.sourceMissing }
        let counts = try ProfileDatabaseStorage.validate(output, files: snapshot.manifest.files.count)
        try Task.checkCancellation()
        let info = ProfileDatabase.Info(
            commit: snapshot.commit,
            tvsTree: snapshot.manifest.tree,
            installedAt: now(),
            importerVersion: builder.fingerprint,
            counts: counts
        )
        let build = try storage.install(output, info: info, snapshot: snapshot)
        if collectGarbage { storage.collectGarbage(keeping: snapshot.blobs) }
        return .installed(info, build)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

/// Files done so far, shared by the parallel downloads.
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: ProfileDatabase.Progress

    init(_ progress: ProfileDatabase.Progress) {
        self.progress = progress
    }

    func add(bytes: Int) -> ProfileDatabase.Progress {
        lock.lock()
        defer { lock.unlock() }
        progress.completedFiles += 1
        progress.completedBytes += bytes
        return progress
    }
}

// MARK: - Storage

/// The database folder. Only the worker of one operation at a time touches it.
struct ProfileDatabaseStorage: Sendable {
    /// A verified revision: what to rebuild from.
    struct Snapshot: Codable, Equatable, Sendable {
        let commit: String
        let root: IRDBRoot
        let manifest: IRDBManifest

        var blobs: Set<String> {
            var shas = Set(manifest.files.map(\.sha))
            if let license = root.license { shas.insert(license.sha) }
            if let readme = root.readme { shas.insert(readme.sha) }
            return shas
        }
    }

    struct LatestCache: Codable, Equatable, Sendable {
        let etag: String?
        let commit: String
        /// The TVs tree of `commit`, once known.
        let tvsTree: String?
    }

    let root: URL
    /// A symlink to "builds/<uuid>".
    var current: URL { root.appendingPathComponent("current", isDirectory: false) }
    var builds: URL { root.appendingPathComponent("builds", isDirectory: true) }
    var source: URL { root.appendingPathComponent("source", isDirectory: true) }
    var blobs: URL { source.appendingPathComponent("blobs", isDirectory: true) }
    var latestURL: URL { source.appendingPathComponent("latest.json") }

    private var fileManager: FileManager { .default }

    /// The build `current` points to.
    func currentBuild() -> URL? {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: current.path) else { return nil }
        let parts = target.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "builds", UUID(uuidString: String(parts[1])) != nil else { return nil }
        return builds.appendingPathComponent(String(parts[1]), isDirectory: true)
    }

    /// Creates the folder, removes interrupted and superseded builds and returns what is installed.
    func open() throws -> (info: ProfileDatabase.Info?, build: URL?) {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromBackup(root)
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        where name.hasPrefix("incoming-") || name.hasPrefix("current.") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        // Anything but a symlink named "current" is not ours.
        if let attributes = try? fileManager.attributesOfItem(atPath: current.path),
           attributes[.type] as? FileAttributeType != .typeSymbolicLink {
            try? fileManager.removeItem(at: current)
        }
        let build = currentBuild()
        for name in (try? fileManager.contentsOfDirectory(atPath: builds.path)) ?? [] where name != build?.lastPathComponent {
            try? fileManager.removeItem(at: builds.appendingPathComponent(name))
        }
        guard let build,
              let data = try? readRegularFile(build.appendingPathComponent("meta.json"), limit: 1 << 16),
              let info = try? Self.decoder.decode(ProfileDatabase.Info.self, from: data),
              GitObjectHash.isSHA(info.commit), GitObjectHash.isSHA(info.tvsTree),
              fileManager.fileExists(atPath: build.appendingPathComponent("index.json").path) else {
            return (nil, nil)
        }
        return (info, build)
    }

    func prepareSource() throws {
        do {
            try fileManager.createDirectory(at: blobs, withIntermediateDirectories: true)
        } catch {
            throw ProfileDatabaseError.storage(error.localizedDescription)
        }
    }

    func removeAll() throws {
        do {
            if fileManager.fileExists(atPath: root.path) { try fileManager.removeItem(at: root) }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try excludeFromBackup(root)
        } catch {
            throw ProfileDatabaseError.storage(error.localizedDescription)
        }
    }

    // MARK: Blobs

    private func blobURL(_ sha: String) -> URL? {
        GitObjectHash.isSHA(sha) ? blobs.appendingPathComponent(sha, isDirectory: false) : nil
    }

    func hasBlob(_ sha: String, size: Int) -> Bool {
        (try? readBlob(sha, size: size)) != nil
    }

    /// A stored blob, checked again: a damaged file is deleted and reported as missing.
    func readBlob(_ sha: String, size: Int) throws -> Data {
        guard let url = blobURL(sha), size >= 0, size <= IRDBLimits.maxFileBytes else {
            throw ProfileDatabaseError.sourceMissing
        }
        guard let data = try? readRegularFile(url, limit: size) else { throw ProfileDatabaseError.sourceMissing }
        guard data.count == size, GitObjectHash.blob(data) == sha else {
            try? fileManager.removeItem(at: url)
            throw ProfileDatabaseError.sourceMissing
        }
        return data
    }

    func writeBlob(_ data: Data, sha: String) throws {
        guard let url = blobURL(sha), GitObjectHash.blob(data) == sha else {
            throw ProfileDatabaseError.integrity(path: sha)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProfileDatabaseError.storage(error.localizedDescription)
        }
    }

    /// Removes blobs of earlier revisions (and leftovers of interrupted writes).
    func collectGarbage(keeping keep: Set<String>) {
        for name in (try? fileManager.contentsOfDirectory(atPath: blobs.path)) ?? [] where !keep.contains(name) {
            try? fileManager.removeItem(at: blobs.appendingPathComponent(name))
        }
    }

    // MARK: Snapshot

    /// The manifest of the installed revision, with the same structural checks as a download.
    func loadSnapshot() -> Snapshot? {
        guard let build = currentBuild(),
              let data = try? readRegularFile(build.appendingPathComponent("manifest.json"), limit: IRDBLimits.maxListingBytes),
              let snapshot = try? Self.decoder.decode(Snapshot.self, from: data) else {
            return nil
        }
        func valid(_ blob: IRDBRoot.Blob?, limit: Int) -> Bool {
            blob.map { GitObjectHash.isSHA($0.sha) && (0...limit).contains($0.size) } ?? true
        }
        var paths = Set<[UInt8]>()
        guard GitObjectHash.isSHA(snapshot.commit), GitObjectHash.isSHA(snapshot.root.tree), GitObjectHash.isSHA(snapshot.root.tvs),
              snapshot.manifest.tree == snapshot.root.tvs,
              valid(snapshot.root.license, limit: IRDBLimits.maxLicenseBytes), valid(snapshot.root.readme, limit: IRDBLimits.maxReadmeBytes),
              snapshot.manifest.files.count <= IRDBLimits.maxFiles,
              snapshot.manifest.files.allSatisfy({ file in
                  GitObjectHash.isSHA(file.sha) && (0...IRDBLimits.maxFileBytes).contains(file.size)
                      && IRDBClient.isSafeRelativePath(file.path) && paths.insert(Array(file.path.utf8)).inserted
              }) else {
            return nil
        }
        return snapshot
    }

    func loadLatest() -> LatestCache? {
        guard let data = try? readRegularFile(latestURL, limit: 4096),
              let cache = try? Self.decoder.decode(LatestCache.self, from: data),
              GitObjectHash.isSHA(cache.commit), cache.tvsTree.map(GitObjectHash.isSHA) ?? true else { return nil }
        return cache
    }

    func saveLatest(_ cache: LatestCache) {
        try? fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try? Self.encoder.encode(cache).write(to: latestURL, options: .atomic)
    }

    // MARK: Install

    /// Writes the build (with meta.json and the manifest) into `builds/<uuid>/` and points `current` at it with one
    /// rename(2): on any error `current` keeps pointing at the old build, and nothing after the rename can fail.
    /// The previous build stays until the next `open()` for catalogs still reading it; older ones are removed.
    func install(_ files: [ProfileFile], info: ProfileDatabase.Info, snapshot: Snapshot) throws -> URL {
        guard files.allSatisfy({ Self.isOutputPath($0.path) }) else {
            throw ProfileDatabaseError.buildFailed("unexpected output file")
        }
        let id = UUID().uuidString
        let incoming = root.appendingPathComponent("incoming-\(id)", isDirectory: true)
        let build = builds.appendingPathComponent(id, isDirectory: true)
        let previous = currentBuild()
        do {
            try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
            for file in files {
                let url = incoming.appendingPathComponent(file.path, isDirectory: false)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: url)
            }
            try Self.encoder.encode(info).write(to: incoming.appendingPathComponent("meta.json"))
            try Self.encoder.encode(snapshot).write(to: incoming.appendingPathComponent("manifest.json"))
            try fileManager.createDirectory(at: builds, withIntermediateDirectories: true)
            try fileManager.moveItem(at: incoming, to: build)
        } catch {
            try? fileManager.removeItem(at: incoming)
            throw ProfileDatabaseError.storage(error.localizedDescription)
        }
        let link = root.appendingPathComponent("current.\(id)", isDirectory: false)
        do {
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: "builds/\(id)")
            guard rename(link.path, current.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: link)
            try? fileManager.removeItem(at: build)
            throw ProfileDatabaseError.storage(error.localizedDescription)
        }
        for name in (try? fileManager.contentsOfDirectory(atPath: builds.path)) ?? []
        where name != id && name != previous?.lastPathComponent {
            try? fileManager.removeItem(at: builds.appendingPathComponent(name))
        }
        return build
    }

    /// Checks the importer's output before it replaces anything: known file names only, a readable index whose
    /// brand files are all there, a power scan list.
    static func validate(_ files: [ProfileFile], files inputCount: Int) throws -> ProfileDatabase.Info.Counts {
        var byPath: [String: Data] = [:]
        // The file system may ignore case: "brands/A.json" and "brands/a.json" would be one file.
        var folded = Set<String>()
        for file in files {
            guard isOutputPath(file.path), folded.insert(file.path.lowercased()).inserted else {
                throw ProfileDatabaseError.buildFailed("unexpected output file")
            }
            byPath[file.path] = file.data
        }
        struct Index: Decodable {
            struct Brand: Decodable {
                let file: String
                let profiles: Int
            }

            let schema: Int
            let brands: [Brand]
        }
        guard let indexData = byPath["index.json"], let index = try? JSONDecoder().decode(Index.self, from: indexData),
              index.schema == 1 else {
            throw ProfileDatabaseError.buildFailed("index.json is missing or invalid")
        }
        for brand in index.brands where byPath[brand.file] == nil || !brand.file.hasPrefix("brands/") {
            throw ProfileDatabaseError.buildFailed("index.json names a missing brand file")
        }
        guard let powerData = byPath["power_scan.json"],
              let power = (try? JSONSerialization.jsonObject(with: powerData)) as? [Any] else {
            throw ProfileDatabaseError.buildFailed("power_scan.json is missing or invalid")
        }
        return .init(
            files: inputCount,
            brands: index.brands.count,
            profiles: index.brands.reduce(0) { $0 + max(0, $1.profiles) },
            powerCodes: power.count
        )
    }

    /// "index.json", "power_scan.json" or "brands/<name>.json" with a plain ASCII name.
    static func isOutputPath(_ path: String) -> Bool {
        if path == "index.json" || path == "power_scan.json" { return true }
        let bytes = Array(path.utf8)
        let prefix = Array("brands/".utf8)
        guard bytes.count > prefix.count + 5, bytes.count <= 120, bytes.starts(with: prefix), path.hasSuffix(".json") else {
            return false
        }
        let name = bytes[prefix.count...]
        guard let first = name.first, first != UInt8(ascii: ".") else { return false }
        return name.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
        }
    }

    // MARK: Helpers

    /// The contents of a regular file (not a symlink) of at most `limit` bytes.
    private func readRegularFile(_ url: URL, limit: Int) throws -> Data {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= limit else {
            throw ProfileDatabaseError.sourceMissing
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw ProfileDatabaseError.sourceMissing }
        return data
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try url.setResourceValues(values)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
