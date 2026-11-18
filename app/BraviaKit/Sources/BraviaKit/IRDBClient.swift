import Foundation
import PultProfiles

/// The Flipper-IRDB commit this app version was tested with.
public enum IRDBPin {
    public static let commit = "d126fb1b6f1e114c52b4a8c19839ea65e3a9c24d"
    /// Root tree of `commit`: anchors LICENSE and README.md of the pinned version.
    public static let rootTree = "daf6bd47b726afca26ebfde1f7c58c70c2250644"
    /// Tree of `TVs/` in `commit`: every downloaded file of the pinned version is verified against it.
    public static let tvsTree = "b078b6acf69b542eaeb8d089d3b91d77d576bbd2"
    /// Commit date, 2026-04-12 06:07:49 UTC.
    public static let date = Date(timeIntervalSince1970: 1_775_974_069)
    public static let url = "https://github.com/Lucaslhm/Flipper-IRDB"
}

/// Limits for data that comes from GitHub (the database is community-maintained, so it is untrusted).
public enum IRDBLimits {
    /// Larger files are not downloaded (the importer skips them as well).
    public static let maxFileBytes = 1 << 20
    public static let maxLicenseBytes = 16 << 10
    public static let maxReadmeBytes = 1 << 20
    /// Downloadable files of `TVs/`; more means the folder is not what the app expects.
    public static let maxFiles = 5000
    public static let maxTotalBytes = 20_000_000
    /// Entries of the recursive tree listing, including the ones that are not downloaded.
    public static let maxEntries = 20_000
    public static let maxPathChars = 200
    /// Path components of a file below `TVs/`, the file name included.
    public static let maxDepth = 8
    public static let maxListingBytes = 8 << 20
}

/// A verified tree of a commit's root folder.
public struct IRDBRoot: Codable, Equatable, Sendable {
    public struct Blob: Codable, Equatable, Sendable {
        public let sha: String
        public let size: Int
    }

    /// SHA of the root tree.
    public let tree: String
    /// SHA of the `TVs` tree.
    public let tvs: String
    public let license: Blob?
    public let readme: Blob?
}

/// The files of `TVs/` that are downloaded, verified against the tree SHA.
public struct IRDBManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        /// Relative to `TVs/`.
        public let path: String
        public let sha: String
        public let size: Int
    }

    /// SHA of the `TVs` tree.
    public let tree: String
    /// In `os.walk` order (files of a folder sorted, then its subfolders sorted), like the Python importer reads them.
    public let files: [File]
    /// Entries that are not downloaded: symlinks, submodules, hidden or unsafe names, too deep, larger than 1 MiB.
    public let skipped: Int

    public var totalBytes: Int { files.reduce(0) { $0 + $1.size } }
}

/// Reads Flipper-IRDB from GitHub: the trees API for the file list, raw.githubusercontent.com for the files.
///
/// Every response is checked before use: tree listings are re-hashed up to the requested tree SHA, every file
/// against its blob SHA. Requests are made only when the user asks for a download.
public struct IRDBClient: Sendable {
    public struct Endpoints: Sendable {
        public var api: String
        public var raw: String

        public static let github = Endpoints(
            api: "https://api.github.com/repos/Lucaslhm/Flipper-IRDB",
            raw: "https://raw.githubusercontent.com/Lucaslhm/Flipper-IRDB"
        )
    }

    public enum LatestCommit: Equatable, Sendable {
        /// The `ETag` still matches: the branch has not moved.
        case unchanged
        case commit(String, etag: String?)
    }

    public static let concurrency = 6
    static let retryDelays: [Double] = [0.5, 1, 2]
    /// A longer `Retry-After` is reported as a limit instead of waiting.
    static let maxRetryAfter: Double = 60

    private let transport: HTTPTransport
    private let endpoints: Endpoints
    private let userAgent: String
    private let sleep: @Sendable (_ seconds: Double) async throws -> Void
    private let now: @Sendable () -> Date

    public init(
        transport: HTTPTransport = IRDBClient.makeTransport(),
        endpoints: Endpoints = .github,
        userAgent: String = IRDBClient.defaultUserAgent(),
        sleep: @escaping @Sendable (_ seconds: Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.endpoints = endpoints
        self.userAgent = Self.isSafeHeaderValue(userAgent) ? userAgent : "openpult/0"
        self.sleep = sleep
        self.now = now
    }

    // MARK: - Session

    /// A session of its own: no cookies, no cache, no credentials, redirects only within the same GitHub host.
    public static func makeSession() -> URLSession {
        makeSession(protocolClasses: nil)
    }

    /// `protocolClasses`: stub protocols for tests.
    static func makeSession(protocolClasses: [AnyClass]?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = concurrency
        return URLSession(configuration: config, delegate: GitHubRedirectPolicy(), delegateQueue: nil)
    }

    public static func makeTransport() -> HTTPTransport {
        IRDBSessionTransport(session: makeSession())
    }

    /// "openpult/<version>": no device, user or install identifiers.
    public static func defaultUserAgent(bundle: Bundle = .main) -> String {
        let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        let clean = String(version.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == ".") }.prefix(20))
        return "openpult/\(clean.isEmpty ? "0" : clean)"
    }

    // MARK: - API

    /// The commit `main` points to. `etag` is the value from an earlier answer; a 304 does not count against the limit.
    public func latestCommit(etag: String?) async throws -> LatestCommit {
        var headers = ["Accept": "application/vnd.github.sha"]
        if let etag, Self.isSafeHeaderValue(etag) { headers["If-None-Match"] = etag }
        let (data, response) = try await fetch("\(endpoints.api)/commits/main", api: true, headers: headers, maxBytes: 4096, allowNotModified: true)
        if response.statusCode == 304 { return .unchanged }
        let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitObjectHash.isSHA(sha) else { throw ProfileDatabaseError.invalidResponse }
        let newTag = response.value(forHTTPHeaderField: "ETag").flatMap { Self.isSafeHeaderValue($0) ? $0 : nil }
        return .commit(sha, etag: newTag)
    }

    /// The root folder of a commit: where `TVs`, `LICENSE` and `README.md` are.
    public func root(commit: String) async throws -> IRDBRoot {
        guard GitObjectHash.isSHA(commit) else { throw ProfileDatabaseError.invalidResponse }
        let (data, _) = try await fetch("\(endpoints.api)/git/trees/\(commit)", api: true, headers: Self.apiHeaders, maxBytes: IRDBLimits.maxListingBytes)
        return try Self.parseRoot(data, commit: commit)
    }

    /// The verified list of files below `TVs/`.
    public func manifest(tree: String) async throws -> IRDBManifest {
        guard GitObjectHash.isSHA(tree) else { throw ProfileDatabaseError.invalidResponse }
        let (data, _) = try await fetch("\(endpoints.api)/git/trees/\(tree)?recursive=1", api: true, headers: Self.apiHeaders, maxBytes: IRDBLimits.maxListingBytes)
        return try Self.parseManifest(data, tree: tree)
    }

    // MARK: - Files

    public struct FileRequest: Hashable, Sendable {
        /// Relative to the repository root, e.g. "TVs/LG/LG_42LB.ir" or "LICENSE".
        public let path: String
        public let sha: String
        public let size: Int

        public init(path: String, sha: String, size: Int) {
            self.path = path
            self.sha = sha
            self.size = size
        }
    }

    /// One file of `commit`, verified against its blob SHA. A mismatch is downloaded once more, then reported.
    public func file(_ file: FileRequest, commit: String) async throws -> Data {
        guard GitObjectHash.isSHA(commit), GitObjectHash.isSHA(file.sha), file.size >= 0 else {
            throw ProfileDatabaseError.invalidResponse
        }
        let url = "\(endpoints.raw)/\(commit)/\(Self.encodePath(file.path))"
        for attempt in 0..<2 {
            let (data, _) = try await fetch(url, api: false, headers: [:], maxBytes: IRDBLimits.maxFileBytes)
            if data.count == file.size, GitObjectHash.blob(data) == file.sha { return data }
            if attempt == 0 { try Task.checkCancellation() }
        }
        throw ProfileDatabaseError.integrity(path: file.path)
    }

    /// Downloads `files` six at a time and hands each verified file to `store` as soon as it arrives.
    /// The first failure cancels the remaining downloads; files stored up to then stay.
    public func download(
        _ files: [FileRequest],
        commit: String,
        store: @escaping @Sendable (FileRequest, Data) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = files.makeIterator()
            var running = 0
            func startNext() -> Bool {
                guard let next = pending.next() else { return false }
                group.addTask {
                    // A verified file is kept even when the download is being cancelled: it serves the resume.
                    let data = try await self.file(next, commit: commit)
                    try await store(next, data)
                }
                return true
            }
            while running < Self.concurrency, startNext() { running += 1 }
            while try await group.next() != nil {
                running -= 1
                try Task.checkCancellation()
                if startNext() { running += 1 }
            }
        }
    }

    // MARK: - Requests

    private static let apiHeaders = [
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    ]

    private enum Attempt {
        case done(Data, HTTPURLResponse)
        case retry(after: Double)
    }

    private func fetch(
        _ address: String,
        api: Bool,
        headers: [String: String],
        maxBytes: Int,
        allowNotModified: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: address), url.scheme == "https" else {
            throw ProfileDatabaseError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        var retries = 0
        while true {
            try Task.checkCancellation()
            switch try await attempt(request, api: api, retries: retries, maxBytes: maxBytes, allowNotModified: allowNotModified) {
            case .done(let data, let response):
                return (data, response)
            case .retry(let delay):
                retries += 1
                do {
                    try await sleep(delay)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw error
                }
            }
        }
    }

    private func attempt(
        _ request: URLRequest,
        api: Bool,
        retries: Int,
        maxBytes: Int,
        allowNotModified: Bool
    ) async throws -> Attempt {
        let canRetry = retries < Self.retryDelays.count
        let backoff = Self.retryDelays[min(retries, Self.retryDelays.count - 1)]
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProfileDatabaseError {
            throw error
        } catch let error as URLError {
            // Only a cancelled task is a cancellation; a request the system cancelled is a network failure.
            if Task.isCancelled { throw CancellationError() }
            switch error.code {
            case .timedOut, .networkConnectionLost:
                if canRetry { return .retry(after: backoff) }
                throw ProfileDatabaseError.network
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                throw ProfileDatabaseError.offline
            default:
                throw ProfileDatabaseError.network
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProfileDatabaseError.network
        }

        let status = response.statusCode
        switch status {
        case 200:
            guard data.count <= maxBytes else { throw ProfileDatabaseError.tooLarge }
            return .done(data, response)
        case 304 where allowNotModified:
            return .done(Data(), response)
        case 404:
            throw ProfileDatabaseError.notFound
        case 403, 429:
            if api, response.value(forHTTPHeaderField: "x-ratelimit-remaining")?.trimmingCharacters(in: .whitespaces) == "0" {
                throw ProfileDatabaseError.rateLimited(resetAt: rateLimitReset(response))
            }
            let retryAfter = self.retryAfter(response)
            if let retryAfter {
                guard retryAfter <= Self.maxRetryAfter, canRetry else {
                    // A nonsensical value gives no time rather than a date centuries away.
                    throw ProfileDatabaseError.rateLimited(resetAt: retryAfter <= 86_400 ? now().addingTimeInterval(retryAfter) : nil)
                }
                return .retry(after: max(retryAfter, backoff))
            }
            if status == 429 {
                if canRetry { return .retry(after: backoff) }
                throw ProfileDatabaseError.rateLimited(resetAt: rateLimitReset(response))
            }
            throw ProfileDatabaseError.server(status: status)
        case 500...599:
            if canRetry { return .retry(after: backoff) }
            throw ProfileDatabaseError.server(status: status)
        default:
            throw ProfileDatabaseError.server(status: status)
        }
    }

    private func rateLimitReset(_ response: HTTPURLResponse) -> Date? {
        guard let text = response.value(forHTTPHeaderField: "x-ratelimit-reset")?.trimmingCharacters(in: .whitespaces),
              let seconds = Int64(text), seconds > 0, seconds < 100_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Seconds from a `Retry-After` header: a number or an HTTP date.
    private func retryAfter(_ response: HTTPURLResponse) -> Double? {
        guard let text = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        if let seconds = Int(text) { return seconds >= 0 ? Double(seconds) : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text) else { return nil }
        return max(0, date.timeIntervalSince(now()))
    }

    static func isSafeHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }

    /// Percent-encodes every path segment; only RFC 3986 unreserved characters stay as they are.
    static func encodePath(_ path: String) -> String {
        splitPath(path)
            .map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
            .joined(separator: "/")
    }

    /// Splits at every "/" scalar (a `Character` split would keep "/" + combining mark together).
    static func splitPath(_ path: String) -> [String] {
        path.unicodeScalars
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// Exact comparison by scalars: `String ==` treats canonically equivalent names as equal, git does not.
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: - Tree listings

    private struct TreeListing: Decodable {
        let sha: String
        let tree: [Entry]
        let truncated: Bool?

        struct Entry: Decodable {
            let path: String
            let mode: String
            let type: String
            let sha: String
            let size: Int?
        }
    }

    private struct ListedEntry {
        let path: String
        let components: [String]
        let kind: GitObjectHash.TreeEntry.Kind
        let sha: String
        let size: Int?
    }

    private static func decodeListing(_ data: Data) throws -> TreeListing {
        guard data.count <= IRDBLimits.maxListingBytes,
              let listing = try? JSONDecoder().decode(TreeListing.self, from: data) else {
            throw ProfileDatabaseError.invalidResponse
        }
        guard listing.truncated != true, listing.tree.count <= IRDBLimits.maxEntries, GitObjectHash.isSHA(listing.sha) else {
            throw listing.tree.count > IRDBLimits.maxEntries ? ProfileDatabaseError.tooLarge : ProfileDatabaseError.invalidResponse
        }
        return listing
    }

    /// Checks an entry of a listing: a well-formed path, a known mode, a SHA, a size for blobs.
    private static func validate(_ entry: TreeListing.Entry) throws -> ListedEntry {
        let path = entry.path
        guard !path.isEmpty, path.utf8.count <= 4096 else { throw ProfileDatabaseError.invalidResponse }
        let components = splitPath(path)
        for component in components {
            guard !component.isEmpty, !same(component, "."), !same(component, ".."), !component.utf8.contains(0) else {
                throw ProfileDatabaseError.invalidResponse
            }
        }
        let kind: GitObjectHash.TreeEntry.Kind
        switch (entry.mode, entry.type) {
        case ("100644", "blob"): kind = .blob(executable: false)
        case ("100755", "blob"): kind = .blob(executable: true)
        case ("120000", "blob"): kind = .symlink
        case ("040000", "tree"), ("40000", "tree"): kind = .tree
        case ("160000", "commit"): kind = .submodule
        default: throw ProfileDatabaseError.invalidResponse
        }
        guard GitObjectHash.isSHA(entry.sha) else { throw ProfileDatabaseError.invalidResponse }
        switch kind {
        case .blob, .symlink:
            guard let size = entry.size, size >= 0 else { throw ProfileDatabaseError.invalidResponse }
        case .tree, .submodule:
            break
        }
        return ListedEntry(path: path, components: components, kind: kind, sha: entry.sha, size: entry.size)
    }

    /// The root listing of a commit. Asked by commit, GitHub echoes the commit id as the listing's `sha`, so this
    /// listing is only checked for consistency and `tree` is computed from its entries: for `.latest` the
    /// commit-to-tree link rests on TLS alone; `.pinned` compares `tree` with `IRDBPin.rootTree`.
    static func parseRoot(_ data: Data, commit: String) throws -> IRDBRoot {
        let listing = try decodeListing(data)
        var entries: [GitObjectHash.TreeEntry] = []
        var tvs: String?
        var license: IRDBRoot.Blob?
        var readme: IRDBRoot.Blob?
        for raw in listing.tree {
            let entry = try validate(raw)
            guard entry.components.count == 1 else { throw ProfileDatabaseError.invalidResponse }
            entries.append(GitObjectHash.TreeEntry(name: entry.path, kind: entry.kind, sha: entry.sha))
            if same(entry.path, "TVs"), entry.kind == .tree {
                tvs = entry.sha
            } else if case .blob = entry.kind, same(entry.path, "LICENSE") {
                license = IRDBRoot.Blob(sha: entry.sha, size: entry.size ?? 0)
            } else if case .blob = entry.kind, same(entry.path, "README.md") {
                readme = IRDBRoot.Blob(sha: entry.sha, size: entry.size ?? 0)
            }
        }
        guard let tree = try? GitObjectHash.tree(entries) else { throw ProfileDatabaseError.invalidResponse }
        guard listing.sha == commit || listing.sha == tree else { throw ProfileDatabaseError.integrity(path: "/") }
        guard let tvs else { throw ProfileDatabaseError.invalidResponse }
        return IRDBRoot(tree: tree, tvs: tvs, license: license, readme: readme)
    }

    /// Re-hashes every folder of the recursive listing and compares it with the listed SHA, up to `tree`.
    static func parseManifest(_ data: Data, tree: String) throws -> IRDBManifest {
        let listing = try decodeListing(data)
        guard listing.sha == tree else { throw ProfileDatabaseError.integrity(path: "TVs") }

        // Keyed by bytes: `String` keys would merge canonically equivalent names that git keeps apart.
        var byPath: [[UInt8]: ListedEntry] = [:]
        var children: [[UInt8]: [GitObjectHash.TreeEntry]] = [[]: []]
        var entries: [ListedEntry] = []
        entries.reserveCapacity(listing.tree.count)
        for raw in listing.tree {
            let entry = try validate(raw)
            let key = Array(entry.path.utf8)
            guard byPath.updateValue(entry, forKey: key) == nil else { throw ProfileDatabaseError.invalidResponse }
            entries.append(entry)
            if entry.kind == .tree, children[key] == nil { children[key] = [] }
        }
        for entry in entries {
            let parent = Array(entry.components.dropLast().joined(separator: "/").utf8)
            if !parent.isEmpty {
                guard byPath[parent]?.kind == .tree else { throw ProfileDatabaseError.invalidResponse }
            }
            children[parent, default: []].append(GitObjectHash.TreeEntry(name: entry.components.last!, kind: entry.kind, sha: entry.sha))
        }
        // Each folder's listed SHA must match its listed contents, and the top must be the requested tree:
        // then nothing in the listing can be missing, added or changed.
        for (key, items) in children {
            let expected = key.isEmpty ? tree : byPath[key]!.sha
            guard (try? GitObjectHash.tree(items)) == expected else {
                throw ProfileDatabaseError.integrity(path: key.isEmpty ? "TVs" : "TVs/" + String(decoding: key, as: UTF8.self))
            }
        }

        var files: [IRDBManifest.File] = []
        var skipped = 0
        for entry in entries {
            switch entry.kind {
            case .tree:
                continue
            case .symlink, .submodule:
                skipped += 1
                continue
            case .blob:
                let size = entry.size ?? 0
                guard isImportable(entry.path, components: entry.components), size <= IRDBLimits.maxFileBytes else {
                    skipped += 1
                    continue
                }
                files.append(IRDBManifest.File(path: entry.path, sha: entry.sha, size: size))
            }
        }
        guard files.count <= IRDBLimits.maxFiles,
              files.reduce(0, { $0 + $1.size }) <= IRDBLimits.maxTotalBytes else {
            throw ProfileDatabaseError.tooLarge
        }
        return IRDBManifest(tree: tree, files: walkOrder(files), skipped: skipped)
    }

    /// The rules of the Python importer's `iter_ir_files`: no hidden names, not too deep, a printable bounded path.
    /// A relative path that stays inside its folder: no empty, "." or ".." components, no NUL, bounded depth.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4096 else { return false }
        let components = splitPath(path)
        return components.count <= IRDBLimits.maxDepth && components.allSatisfy { component in
            !component.isEmpty && !same(component, ".") && !same(component, "..") && !component.utf8.contains(0)
        }
    }

    static func isImportable(_ path: String, components: [String]) -> Bool {
        guard components.count <= IRDBLimits.maxDepth,
              !components.contains(where: { $0.unicodeScalars.first == "." }),
              path.unicodeScalars.count <= IRDBLimits.maxPathChars else { return false }
        return path.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned: return false
            default: return true
            }
        }
    }

    /// `os.walk` order: the files of a folder by code point, then each subfolder by code point.
    static func walkOrder(_ files: [IRDBManifest.File]) -> [IRDBManifest.File] {
        final class Folder {
            var files: [(name: [UInt8], file: IRDBManifest.File)] = []
            var folders: [[UInt8]: Folder] = [:]
        }
        let top = Folder()
        for file in files {
            var folder = top
            let parts = splitPath(file.path).map { Array($0.utf8) }
            for part in parts.dropLast() {
                if let next = folder.folders[part] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            folder.files.append((parts.last ?? [], file))
        }
        var ordered: [IRDBManifest.File] = []
        ordered.reserveCapacity(files.count)
        func walk(_ folder: Folder) {
            for item in folder.files.sorted(by: { $0.name.lexicographicallyPrecedes($1.name) }) { ordered.append(item.file) }
            for name in folder.folders.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) { walk(folder.folders[name]!) }
        }
        walk(top)
        return ordered
    }
}

// MARK: - License

/// The license checks of tools/profiles/import_flipper_irdb.py (ported with Python's string semantics in PultProfiles).
public enum IRDBLicense {
    /// `check_license`: the first two non-blank lines must be the CC0 1.0 legal code title; at most 16 KiB.
    public static func isCC0(_ data: Data) -> Bool {
        data.count <= IRDBLimits.maxLicenseBytes && ProfileImporter.checkLicense(data)
    }

    /// `readme_license_note`: the upstream README excludes early commits from CC0.
    public static func note(readme data: Data?) -> String? {
        guard let data, data.count <= IRDBLimits.maxReadmeBytes else { return nil }
        return ProfileImporter.licenseNote(readme: data)
    }
}

// MARK: - Transport

/// The production transport: like `URLSessionTransport`, but a response stops being read once it is larger than
/// the limit for its host, so an oversized (or decompressed) body never ends up in memory as a whole.
struct IRDBSessionTransport: HTTPTransport {
    let session: URLSession

    static func limit(for url: URL?) -> Int {
        url?.host?.lowercased() == "raw.githubusercontent.com" ? IRDBLimits.maxFileBytes : IRDBLimits.maxListingBytes
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let limit = Self.limit(for: request.url)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw ProfileDatabaseError.invalidResponse
        }
        if http.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw ProfileDatabaseError.tooLarge
        }
        var buffer: [UInt8] = []
        buffer.reserveCapacity(Int(min(max(http.expectedContentLength, 0), Int64(limit))))
        for try await byte in bytes {
            guard buffer.count < limit else {
                bytes.task.cancel()
                throw ProfileDatabaseError.tooLarge
            }
            buffer.append(byte)
        }
        return (Data(buffer), http)
    }
}

// MARK: - Redirects

/// Follows a redirect only to the same GitHub host over HTTPS (e.g. a renamed repository).
final class GitHubRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static let hosts: Set<String> = ["api.github.com", "raw.githubusercontent.com"]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.allows(request.url, from: task.originalRequest?.url) ? request : nil)
    }

    static func allows(_ url: URL?, from original: URL?) -> Bool {
        guard let url, let original, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), hosts.contains(host), host == original.host?.lowercased() else {
            return false
        }
        return true
    }
}
