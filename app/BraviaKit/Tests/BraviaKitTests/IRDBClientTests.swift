import Foundation
import XCTest
@testable import BraviaKit

// MARK: - Fake GitHub

let cc0License = Data("Creative Commons Legal Code\r\n\r\nCC0 1.0 Universal\r\n\r\n    Statement of Purpose\r\n".utf8)

/// A git-compatible tree listing built from files, as the GitHub trees API returns it.
struct FakeTree {
    struct Item {
        var data: Data
        var mode = "100644"
    }

    struct Entry {
        let path: String
        let mode: String
        let type: String
        let sha: String
        let size: Int?

        var json: [String: Any] {
            var object: [String: Any] = ["path": path, "mode": mode, "type": type, "sha": sha, "url": "https://api.github.com/x"]
            if let size { object["size"] = size }
            return object
        }
    }

    /// tree SHA -> direct entries (name, not path).
    private(set) var trees: [String: [Entry]] = [:]
    private(set) var root = ""

    init(_ files: [String: Item]) {
        final class Folder {
            var files: [String: FakeTree.Item] = [:]
            var folders: [String: Folder] = [:]
        }
        let top = Folder()
        for (path, item) in files {
            var folder = top
            let parts = path.components(separatedBy: "/")
            for part in parts.dropLast() {
                if folder.folders[part] == nil { folder.folders[part] = Folder() }
                folder = folder.folders[part]!
            }
            folder.files[parts.last!] = item
        }
        var trees: [String: [Entry]] = [:]
        func hash(_ folder: Folder) -> String {
            var entries: [Entry] = []
            var git: [GitObjectHash.TreeEntry] = []
            for (name, item) in folder.files {
                switch item.mode {
                case "160000":
                    let sha = GitObjectHash.blob(item.data)
                    entries.append(Entry(path: name, mode: item.mode, type: "commit", sha: sha, size: nil))
                    git.append(.init(name: name, kind: .submodule, sha: sha))
                default:
                    let sha = GitObjectHash.blob(item.data)
                    entries.append(Entry(path: name, mode: item.mode, type: "blob", sha: sha, size: item.data.count))
                    let kind: GitObjectHash.TreeEntry.Kind = item.mode == "120000" ? .symlink : .blob(executable: item.mode == "100755")
                    git.append(.init(name: name, kind: kind, sha: sha))
                }
            }
            for (name, sub) in folder.folders {
                let sha = hash(sub)
                entries.append(Entry(path: name, mode: "040000", type: "tree", sha: sha, size: nil))
                git.append(.init(name: name, kind: .tree, sha: sha))
            }
            let sha = try! GitObjectHash.tree(git)
            trees[sha] = entries
            return sha
        }
        root = hash(top)
        self.trees = trees
    }

    /// The listing of a tree: direct entries, or every entry below it with paths relative to it.
    func listing(_ sha: String, recursive: Bool) -> [Entry]? {
        guard let entries = trees[sha] else { return nil }
        guard recursive else { return entries }
        var all: [Entry] = []
        for entry in entries {
            all.append(entry)
            if entry.type == "tree" {
                for child in listing(entry.sha, recursive: true) ?? [] {
                    all.append(Entry(path: "\(entry.path)/\(child.path)", mode: child.mode, type: child.type, sha: child.sha, size: child.size))
                }
            }
        }
        return all
    }

    func sha(of path: String) -> String? {
        var current = root
        let parts = path.components(separatedBy: "/")
        for (index, part) in parts.enumerated() {
            guard let entry = trees[current]?.first(where: { $0.path == part }) else { return nil }
            if index == parts.count - 1 { return entry.sha }
            current = entry.sha
        }
        return nil
    }

    static func json(sha: String, entries: [Entry], truncated: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: ["sha": sha, "url": "https://api.github.com/x", "tree": entries.map(\.json), "truncated": truncated])
    }
}

/// Serves fake repositories over the GitHub trees API and raw.githubusercontent.com. Thread-safe.
final class FakeGitHub: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var commits: [String: (tree: FakeTree, files: [String: FakeTree.Item])] = [:]
    private var main = ""
    private var recorded: [URLRequest] = []
    private var hook: ((URLRequest) throws -> MockResponse?)?
    private var onRequest: ((URLRequest) -> Void)?
    private var running = 0
    private var peak = 0
    private var delay: UInt64 = 0

    var maxRunning: Int { lock.withLock { peak } }
    var latency: UInt64 {
        get { lock.withLock { delay } }
        set { lock.withLock { delay = newValue } }
    }

    /// Adds a commit with these files (paths from the repository root) and returns its id.
    @discardableResult
    func add(_ files: [String: FakeTree.Item], main isMain: Bool = true) -> String {
        let tree = FakeTree(files)
        let commit = GitObjectHash.blob(Data("commit \(tree.root) \(UUID())".utf8))
        lock.lock()
        commits[commit] = (tree, files)
        if isMain { main = commit }
        lock.unlock()
        return commit
    }

    func tree(_ commit: String) -> FakeTree {
        lock.lock()
        defer { lock.unlock() }
        return commits[commit]!.tree
    }

    /// Runs before the fake answers; a non-nil response replaces the answer.
    func setHook(_ hook: ((URLRequest) throws -> MockResponse?)?) {
        lock.lock()
        self.hook = hook
        lock.unlock()
    }

    func setOnRequest(_ callback: ((URLRequest) -> Void)?) {
        lock.lock()
        onRequest = callback
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var apiRequests: [URLRequest] { requests.filter { $0.url?.host == "api.github.com" } }
    var rawPaths: [String] { requests.filter { $0.url?.host == "raw.githubusercontent.com" }.map { Self.rawPath($0) } }

    func reset() {
        lock.lock()
        recorded = []
        peak = 0
        lock.unlock()
    }

    static func rawPath(_ request: URLRequest) -> String {
        // /Lucaslhm/Flipper-IRDB/<commit>/<path>
        let path = request.url!.path(percentEncoded: false)
        return path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true).dropFirst(3).joined()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (hook, onRequest) = lock.withLock {
            recorded.append(request)
            running += 1
            peak = max(peak, running)
            return (self.hook, self.onRequest)
        }
        defer { lock.withLock { running -= 1 } }
        onRequest?(request)
        let latency = self.latency
        if latency > 0 { try await Task.sleep(nanoseconds: latency) }
        let response = try hook?(request) ?? answer(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (response.body, http)
    }

    private func answer(_ request: URLRequest) -> MockResponse {
        let url = request.url!
        lock.lock()
        let commits = self.commits
        let main = self.main
        lock.unlock()
        let path = url.path(percentEncoded: false)
        if url.host == "api.github.com" {
            if path == "/repos/Lucaslhm/Flipper-IRDB/commits/main" {
                let etag = "W/\"\(main.prefix(12))\""
                if request.value(forHTTPHeaderField: "If-None-Match") == etag { return MockResponse(status: 304) }
                return MockResponse(status: 200, body: Data(main.utf8), headers: ["ETag": etag])
            }
            let prefix = "/repos/Lucaslhm/Flipper-IRDB/git/trees/"
            guard path.hasPrefix(prefix) else { return MockResponse(status: 404) }
            let sha = String(path.dropFirst(prefix.count))
            let recursive = url.query == "recursive=1"
            if let commit = commits[sha] {
                // Like GitHub: asked by commit, the listing's sha is the commit id.
                return MockResponse(status: 200, body: FakeTree.json(sha: sha, entries: commit.tree.listing(commit.tree.root, recursive: recursive)!))
            }
            for commit in commits.values {
                if let entries = commit.tree.listing(sha, recursive: recursive) {
                    return MockResponse(status: 200, body: FakeTree.json(sha: sha, entries: entries))
                }
            }
            return MockResponse(status: 404)
        }
        if url.host == "raw.githubusercontent.com" {
            let parts = path.split(separator: "/", maxSplits: 3).map(String.init)
            guard parts.count == 4, let commit = commits[parts[2]], let item = commit.files[parts[3]] else {
                return MockResponse(status: 404)
            }
            return MockResponse(status: 200, body: item.data)
        }
        return MockResponse(status: 404)
    }
}

/// Serves "<host>/stub/<n>" with n bytes (with a Content-Length for "?length"), "<host>/redirect/<url>" with a 302.
final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.path(percentEncoded: false)
        if path.hasPrefix("/redirect/") {
            let target = URL(string: String(url.absoluteString.split(separator: "/redirect/", maxSplits: 1)[1]))!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let size = Int(url.lastPathComponent) ?? 0
        var headers: [String: String] = [:]
        if url.query == "length" { headers["Content-Length"] = "\(size)" }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var remaining = size
        while remaining > 0 {
            let chunk = min(remaining, 256 << 10)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: chunk))
            remaining -= chunk
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Records the requested sleeps instead of sleeping.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var durations: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sleep(_ seconds: Double) async throws {
        lock.withLock { recorded.append(seconds) }
        try Task.checkCancellation()
    }
}

func irFile(_ text: String) -> FakeTree.Item {
    FakeTree.Item(data: Data("Filetype: IR signals file\nVersion: 1\n# \(text)\n".utf8))
}

// MARK: - Tests

final class IRDBClientTests: XCTestCase {
    private func makeClient(_ server: HTTPTransport, sleeper: SleepRecorder = SleepRecorder(), now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> IRDBClient {
        IRDBClient(transport: server, userAgent: "openpult/1.0", sleep: { try await sleeper.sleep($0) }, now: { now })
    }

    private func repository() -> [String: FakeTree.Item] {
        [
            "LICENSE": .init(data: cc0License),
            "README.md": .init(data: Data("> **Commits prior to [2319685](https://x/commit/2319685) are not covered.**".utf8)),
            "ACs/ignored.ir": irFile("not a TV"),
            "TVs/LG/LG_42LB.ir": irFile("lg"),
            "TVs/LG/Old/LG_1999.ir": irFile("old lg"),
            "TVs/LG/LG 32.ir": .init(data: Data("Filetype: IR signals file\n# exec\n".utf8), mode: "100755"),
            "TVs/Acme": irFile("brand file in TVs/"),
            "TVs/Zenco/Z1.ir": irFile("z"),
            "TVs/Zenco/z0.ir": irFile("lower case sorts after upper case"),
            "TVs/\u{C4}rger/A.ir": irFile("non-ASCII folder"),
            "TVs/LG/.hidden.ir": irFile("hidden"),
            "TVs/.git/config": irFile("hidden folder"),
            "TVs/LG/link.ir": .init(data: Data("LG_42LB.ir".utf8), mode: "120000"),
            "TVs/Sub": .init(data: Data("submodule".utf8), mode: "160000"),
            "TVs/Deep/1/2/3/4/5/6/7/x.ir": irFile("depth 9"),
            "TVs/Deep/1/2/3/4/5/6/ok.ir": irFile("depth 8"),
            "TVs/LG/bad\u{7}name.ir": irFile("control character"),
            "TVs/LG/huge.ir": .init(data: Data(count: IRDBLimits.maxFileBytes + 1)),
        ]
    }

    func testManifestIsVerifiedAndInWalkOrder() async throws {
        let server = FakeGitHub()
        let commit = server.add(repository())
        let client = makeClient(server)
        let root = try await client.root(commit: commit)
        XCTAssertEqual(root.tree, server.tree(commit).root)
        XCTAssertEqual(root.license?.sha, GitObjectHash.blob(cc0License))
        XCTAssertNotNil(root.readme)
        let manifest = try await client.manifest(tree: root.tvs)
        XCTAssertEqual(manifest.files.map(\.path), [
            "Acme",
            "Deep/1/2/3/4/5/6/ok.ir",
            "LG/LG 32.ir",
            "LG/LG_42LB.ir",
            "LG/Old/LG_1999.ir",
            "Zenco/Z1.ir",
            "Zenco/z0.ir",
            "\u{C4}rger/A.ir",
        ])
        // hidden file, hidden folder, symlink, submodule, too deep, control character, larger than 1 MiB
        XCTAssertEqual(manifest.skipped, 7)
        XCTAssertEqual(server.apiRequests.count, 2)
        XCTAssertEqual(server.apiRequests.last?.url?.query, "recursive=1")
    }

    func testFilesAreFetchedByCommitWithEncodedPaths() async throws {
        let server = FakeGitHub()
        let name = "TVs/\u{C4}rger Co/A #1?%.ir"
        let commit = server.add(["LICENSE": .init(data: cc0License), name: irFile("x")])
        let client = makeClient(server)
        let data = irFile("x").data
        let fetched = try await client.file(.init(path: name, sha: GitObjectHash.blob(data), size: data.count), commit: commit)
        XCTAssertEqual(fetched, data)
        let url = try XCTUnwrap(server.requests.last?.url)
        XCTAssertEqual(url.host, "raw.githubusercontent.com")
        XCTAssertEqual(url.path(percentEncoded: true), "/Lucaslhm/Flipper-IRDB/\(commit)/TVs/%C3%84rger%20Co/A%20%231%3F%25.ir")
        XCTAssertNil(url.query)
    }

    func testRequestsCarryNoIdentifiers() async throws {
        let server = FakeGitHub()
        let commit = server.add(repository())
        _ = try await makeClient(server).root(commit: commit)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "openpult/1.0")
        XCTAssertEqual(Set(request.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []), ["user-agent", "accept", "x-github-api-version"])
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertTrue(IRDBClient.defaultUserAgent().hasPrefix("openpult/"))
        XCTAssertFalse(IRDBClient.defaultUserAgent().contains(" "))
    }

    func testSessionIsEphemeralWithoutCookiesOrCache() {
        let config = IRDBClient.makeSession().configuration
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.timeoutIntervalForRequest, 20)
        let api = URL(string: "https://api.github.com/repos/Lucaslhm/Flipper-IRDB/commits/main")
        let raw = URL(string: "https://raw.githubusercontent.com/Lucaslhm/Flipper-IRDB/x/TVs/a.ir")
        XCTAssertTrue(GitHubRedirectPolicy.allows(URL(string: "https://api.github.com/repositories/1/commits/main"), from: api))
        XCTAssertTrue(GitHubRedirectPolicy.allows(URL(string: "https://raw.githubusercontent.com/New/Name/x/TVs/a.ir"), from: raw))
        XCTAssertTrue(GitHubRedirectPolicy.allows(URL(string: "https://API.github.com:443/x"), from: api))
        for bad in ["http://api.github.com/x", "https://raw.githubusercontent.com/x", "https://gist.githubusercontent.com/x",
                    "https://objects.githubusercontent.com/x", "https://github.com.evil.example/x", "https://evilgithub.com/x",
                    "https://api.github.com:8443/x", "https://user:pass@api.github.com/x"] {
            XCTAssertFalse(GitHubRedirectPolicy.allows(URL(string: bad), from: api), bad)
        }
        XCTAssertFalse(GitHubRedirectPolicy.allows(api, from: nil))
    }

    func testTransportStopsReadingOversizedResponses() async throws {
        let transport = IRDBSessionTransport(session: IRDBClient.makeSession(protocolClasses: [StubURLProtocol.self]))
        func get(_ address: String) async throws -> Data {
            try await transport.send(URLRequest(url: URL(string: address)!)).0
        }
        let limit = IRDBLimits.maxFileBytes
        let exact = try await get("https://raw.githubusercontent.com/stub/\(limit)")
        XCTAssertEqual(exact.count, limit)
        for address in ["https://raw.githubusercontent.com/stub/\(limit + 1)", "https://raw.githubusercontent.com/stub/\(limit + 1)?length"] {
            do {
                _ = try await get(address)
                XCTFail("expected tooLarge for \(address)")
            } catch {
                XCTAssertEqual(error as? ProfileDatabaseError, .tooLarge, address)
            }
        }
        let listing = try await get("https://api.github.com/stub/\(limit * 2)")
        XCTAssertEqual(listing.count, limit * 2, "API answers may be larger than one file")
        do {
            _ = try await get("https://api.github.com/stub/\(IRDBLimits.maxListingBytes + 1)")
            XCTFail("expected tooLarge")
        } catch {
            XCTAssertEqual(error as? ProfileDatabaseError, .tooLarge)
        }
    }

    func testRedirectsToOtherHostsAreNotFollowed() async throws {
        let transport = IRDBSessionTransport(session: IRDBClient.makeSession(protocolClasses: [StubURLProtocol.self]))
        let (_, response) = try await transport.send(URLRequest(url: URL(string: "https://api.github.com/redirect/https://gist.githubusercontent.com/stub/10")!))
        XCTAssertEqual(response.statusCode, 302)
        let (data, followed) = try await transport.send(URLRequest(url: URL(string: "https://api.github.com/redirect/https://api.github.com/stub/10")!))
        XCTAssertEqual(followed.statusCode, 200)
        XCTAssertEqual(data.count, 10)
    }

    // MARK: Listing checks

    private func listing(_ files: [String: FakeTree.Item], edit: (inout [FakeTree.Entry]) -> Void = { _ in }, truncated: Bool = false) -> (tree: String, data: Data) {
        let tree = FakeTree(files)
        var entries = tree.listing(tree.root, recursive: true)!
        edit(&entries)
        return (tree.root, FakeTree.json(sha: tree.root, entries: entries, truncated: truncated))
    }

    private func assertManifestError(_ expected: ProfileDatabaseError, _ data: Data, tree: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try IRDBClient.parseManifest(data, tree: tree), file: file, line: line) { error in
            XCTAssertEqual(error as? ProfileDatabaseError, expected, file: file, line: line)
        }
    }

    func testTruncatedListingIsRejected() {
        let (tree, data) = listing(["A/a.ir": irFile("a")], truncated: true)
        assertManifestError(.invalidResponse, data, tree: tree)
    }

    func testForeignModesAreRejectedOrSkipped() throws {
        let (tree, data) = listing(["A/a.ir": irFile("a")]) { entries in
            entries = entries.map { $0.type == "blob" ? .init(path: $0.path, mode: "100664", type: "blob", sha: $0.sha, size: $0.size) : $0 }
        }
        assertManifestError(.invalidResponse, data, tree: tree)
        let (tree2, data2) = listing(["A/a.ir": irFile("a")]) { entries in
            entries = entries.map { $0.type == "blob" ? .init(path: $0.path, mode: "040000", type: "blob", sha: $0.sha, size: $0.size) : $0 }
        }
        assertManifestError(.invalidResponse, data2, tree: tree2)

        // Symlinks and submodules count for the tree SHA but are never downloaded.
        let (tree3, data3) = listing(["A/a.ir": irFile("a"), "A/l.ir": .init(data: Data("a.ir".utf8), mode: "120000"), "S": .init(data: Data("s".utf8), mode: "160000")])
        let manifest = try IRDBClient.parseManifest(data3, tree: tree3)
        XCTAssertEqual(manifest.files.map(\.path), ["A/a.ir"])
        XCTAssertEqual(manifest.skipped, 2)
    }

    func testUnsafePathsAreRejected() {
        for bad in ["../etc/passwd", "A/../../x.ir", "A/./x.ir", "A//x.ir", "/abs.ir", "A/x.ir/", "A/x\u{0}.ir"] {
            let (tree, data) = listing(["A/a.ir": irFile("a")]) { entries in
                entries.append(.init(path: bad, mode: "100644", type: "blob", sha: GitObjectHash.blob(Data()), size: 0))
            }
            assertManifestError(.invalidResponse, data, tree: tree)
        }
    }

    func testTamperedListingsFailTheMerkleCheck() {
        let files: [String: FakeTree.Item] = ["A/a.ir": irFile("a"), "A/b.ir": irFile("b"), "B/c.ir": irFile("c")]
        // A changed blob SHA.
        var (tree, data) = listing(files) { entries in
            let index = entries.firstIndex { $0.path == "A/b.ir" }!
            let entry = entries[index]
            entries[index] = .init(path: entry.path, mode: entry.mode, type: entry.type, sha: GitObjectHash.blob(Data("evil".utf8)), size: entry.size)
        }
        assertManifestError(.integrity(path: "TVs/A"), data, tree: tree)
        // A file left out.
        (tree, data) = listing(files) { $0.removeAll { $0.path == "B/c.ir" } }
        assertManifestError(.integrity(path: "TVs/B"), data, tree: tree)
        // A file added.
        (tree, data) = listing(files) { $0.append(.init(path: "B/d.ir", mode: "100644", type: "blob", sha: GitObjectHash.blob(Data()), size: 0)) }
        assertManifestError(.integrity(path: "TVs/B"), data, tree: tree)
        // A consistent listing of another tree.
        let other = listing(["A/a.ir": irFile("other")])
        assertManifestError(.integrity(path: "TVs"), other.data, tree: tree)
        // A file whose folder is not listed.
        (tree, data) = listing(files) { $0.removeAll { $0.path == "A" } }
        assertManifestError(.invalidResponse, data, tree: tree)
        // A tree listed twice.
        (tree, data) = listing(files) { $0.append($0.first { $0.path == "A" }!) }
        assertManifestError(.invalidResponse, data, tree: tree)
    }

    func testLimitsAreEnforced() throws {
        func manifest(count: Int, size: Int) throws -> IRDBManifest {
            // Fake blob SHAs with sizes: the listing stays consistent, nothing is downloaded.
            var git: [GitObjectHash.TreeEntry] = []
            var entries: [FakeTree.Entry] = []
            for index in 0..<count {
                let sha = GitObjectHash.blob(Data("\(index)".utf8))
                git.append(.init(name: "\(index).ir", kind: .blob(executable: false), sha: sha))
                entries.append(.init(path: "A/\(index).ir", mode: "100644", type: "blob", sha: sha, size: size))
            }
            let folder = try GitObjectHash.tree(git)
            let root = try GitObjectHash.tree([.init(name: "A", kind: .tree, sha: folder)])
            entries.insert(.init(path: "A", mode: "040000", type: "tree", sha: folder, size: nil), at: 0)
            return try IRDBClient.parseManifest(FakeTree.json(sha: root, entries: entries), tree: root)
        }
        XCTAssertEqual(try manifest(count: IRDBLimits.maxFiles, size: 10).files.count, IRDBLimits.maxFiles)
        XCTAssertThrowsError(try manifest(count: IRDBLimits.maxFiles + 1, size: 10)) { XCTAssertEqual($0 as? ProfileDatabaseError, .tooLarge) }
        XCTAssertThrowsError(try manifest(count: 20, size: IRDBLimits.maxFileBytes)) { XCTAssertEqual($0 as? ProfileDatabaseError, .tooLarge) }
        let oversized = try manifest(count: 3, size: IRDBLimits.maxFileBytes + 1)
        XCTAssertEqual(oversized.files, [])
        XCTAssertEqual(oversized.skipped, 3)
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(try IRDBClient.parseManifest(Data("{".utf8), tree: String(repeating: "a", count: 40))) {
            XCTAssertEqual($0 as? ProfileDatabaseError, .invalidResponse)
        }
        let commit = String(repeating: "c", count: 40)
        XCTAssertThrowsError(try IRDBClient.parseRoot(FakeTree.json(sha: "nope", entries: []), commit: commit)) {
            XCTAssertEqual($0 as? ProfileDatabaseError, .invalidResponse)
        }
        // A root without TVs.
        let tree = FakeTree(["LICENSE": .init(data: cc0License)])
        XCTAssertThrowsError(try IRDBClient.parseRoot(FakeTree.json(sha: commit, entries: tree.listing(tree.root, recursive: false)!), commit: commit)) {
            XCTAssertEqual($0 as? ProfileDatabaseError, .invalidResponse)
        }
        // The listing of something else.
        let full = FakeTree(["LICENSE": .init(data: cc0License), "TVs/a.ir": irFile("a")])
        XCTAssertThrowsError(try IRDBClient.parseRoot(FakeTree.json(sha: String(repeating: "d", count: 40), entries: full.listing(full.root, recursive: false)!), commit: commit)) {
            XCTAssertEqual($0 as? ProfileDatabaseError, .integrity(path: "/"))
        }
        // Root entries are single names.
        XCTAssertThrowsError(try IRDBClient.parseRoot(FakeTree.json(sha: commit, entries: full.listing(full.root, recursive: true)!), commit: commit)) {
            XCTAssertEqual($0 as? ProfileDatabaseError, .invalidResponse)
        }
    }

    // MARK: Retries and errors

    func testShaMismatchIsDownloadedOnceMoreThenReported() async throws {
        let server = FakeGitHub()
        let data = irFile("a").data
        let commit = server.add(["TVs/A/a.ir": .init(data: data)])
        let request = IRDBClient.FileRequest(path: "TVs/A/a.ir", sha: GitObjectHash.blob(data), size: data.count)
        var bad = 1
        let lock = NSLock()
        server.setHook { _ in
            lock.lock()
            defer { lock.unlock() }
            guard bad > 0 else { return nil }
            bad -= 1
            return MockResponse(status: 200, body: Data("Filetype: IR signals file\nVersion: 1\n# evil\n".utf8))
        }
        let fetched = try await makeClient(server).file(request, commit: commit)
        XCTAssertEqual(fetched, data)
        XCTAssertEqual(server.requests.count, 2)

        server.reset()
        server.setHook { _ in MockResponse(status: 200, body: Data("evil".utf8)) }
        do {
            _ = try await makeClient(server).file(request, commit: commit)
            XCTFail("expected an integrity error")
        } catch {
            XCTAssertEqual(error as? ProfileDatabaseError, .integrity(path: "TVs/A/a.ir"))
        }
        XCTAssertEqual(server.requests.count, 2)
    }

    func testRetryAfterIsHonoured() async throws {
        let server = FakeGitHub()
        let data = irFile("a").data
        let commit = server.add(["TVs/A/a.ir": .init(data: data)])
        var throttled = true
        let lock = NSLock()
        server.setHook { _ in
            lock.lock()
            defer { lock.unlock() }
            guard throttled else { return nil }
            throttled = false
            return MockResponse(status: 429, headers: ["Retry-After": "7"])
        }
        let sleeper = SleepRecorder()
        let fetched = try await makeClient(server, sleeper: sleeper).file(.init(path: "TVs/A/a.ir", sha: GitObjectHash.blob(data), size: data.count), commit: commit)
        XCTAssertEqual(fetched, data)
        XCTAssertEqual(sleeper.durations, [7])

        // Nonsense: no time at all.
        server.setHook { _ in MockResponse(status: 429, headers: ["Retry-After": "9000000000000000000"]) }
        do {
            _ = try await makeClient(server, sleeper: sleeper).file(.init(path: "TVs/A/a.ir", sha: GitObjectHash.blob(data), size: data.count), commit: commit)
            XCTFail("expected a limit error")
        } catch {
            XCTAssertEqual(error as? ProfileDatabaseError, .rateLimited(resetAt: nil))
        }

        // Far in the future: reported, not waited for.
        server.setHook { _ in MockResponse(status: 429, headers: ["Retry-After": "3600"]) }
        do {
            _ = try await makeClient(server, sleeper: sleeper).file(.init(path: "TVs/A/a.ir", sha: GitObjectHash.blob(data), size: data.count), commit: commit)
            XCTFail("expected a limit error")
        } catch {
            XCTAssertEqual(error as? ProfileDatabaseError, .rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_003_600)))
        }
        XCTAssertEqual(sleeper.durations, [7])
    }

    func testServerErrorsAndTimeoutsAreRetriedWithBackoff() async throws {
        let server = FakeGitHub()
        let commit = server.add(repository())
        let lock = NSLock()
        var failures = 3
        server.setHook { _ in
            lock.lock()
            defer { lock.unlock() }
            guard failures > 0 else { return nil }
            failures -= 1
            if failures == 1 { throw URLError(.timedOut) }
            return MockResponse(status: 503)
        }
        let sleeper = SleepRecorder()
        _ = try await makeClient(server, sleeper: sleeper).root(commit: commit)
        XCTAssertEqual(sleeper.durations, [0.5, 1, 2])
        XCTAssertEqual(server.requests.count, 4)

        server.reset()
        server.setHook { _ in MockResponse(status: 502) }
        do {
            _ = try await makeClient(server).root(commit: commit)
            XCTFail("expected a server error")
        } catch {
            XCTAssertEqual(error as? ProfileDatabaseError, .server(status: 502))
        }
        XCTAssertEqual(server.requests.count, 4, "three retries")
    }

    func testNotFoundAndOfflineAreNotRetried() async throws {
        let server = FakeGitHub()
        let commit = server.add(repository())
        let sleeper = SleepRecorder()
        do {
            _ = try await makeClient(server, sleeper: sleeper).file(.init(path: "TVs/missing.ir", sha: GitObjectHash.blob(Data()), size: 0), commit: commit)
            XCTFail("expected not found")
        } catch {
            XCTAssertEqual(error as? ProfileDatabaseError, .notFound)
        }
        server.setHook { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await makeClient(server, sleeper: sleeper).root(commit: commit)
            XCTFail("expected offline")
        } catch {
            XCTAssertEqual(error as? ProfileDatabaseError, .offline)
        }
        XCTAssertEqual(sleeper.durations, [])
        XCTAssertEqual(server.requests.count, 2)
    }

    func testExhaustedAPILimitIsReportedWithTheResetTime() async throws {
        let server = FakeGitHub()
        let commit = server.add(repository())
        server.setHook { _ in
            MockResponse(status: 403, body: Data(#"{"message":"API rate limit exceeded"}"#.utf8),
                         headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800001800"])
        }
        let sleeper = SleepRecorder()
        do {
            _ = try await makeClient(server, sleeper: sleeper).root(commit: commit)
            XCTFail("expected a limit error")
        } catch {
            let reset = Date(timeIntervalSince1970: 1_800_001_800)
            XCTAssertEqual(error as? ProfileDatabaseError, .rateLimited(resetAt: reset))
            let message = try XCTUnwrap((error as? LocalizedError)?.errorDescription)
            XCTAssertTrue(message.contains(reset.formatted(date: .omitted, time: .shortened)), message)
        }
        XCTAssertEqual(sleeper.durations, [], "an exhausted limit is not retried")
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertNotNil(ProfileDatabaseError.rateLimited(resetAt: nil).errorDescription)

        // A 403 without the limit headers is a plain error.
        server.setHook { _ in MockResponse(status: 403) }
        do {
            _ = try await makeClient(server).root(commit: commit)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ProfileDatabaseError, .server(status: 403))
        }
    }

    func testLatestCommitUsesTheETag() async throws {
        let server = FakeGitHub()
        let commit = server.add(repository())
        let client = makeClient(server)
        let first = try await client.latestCommit(etag: nil)
        guard case .commit(let sha, let etag?) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(sha, commit)
        XCTAssertEqual(server.requests.last?.value(forHTTPHeaderField: "Accept"), "application/vnd.github.sha")
        XCTAssertNil(server.requests.last?.value(forHTTPHeaderField: "If-None-Match"))
        let second = try await client.latestCommit(etag: etag)
        XCTAssertEqual(second, .unchanged)
        XCTAssertEqual(server.requests.last?.value(forHTTPHeaderField: "If-None-Match"), etag)
        // An unsafe stored value is not sent.
        _ = try await client.latestCommit(etag: "x\r\nCookie: a")
        XCTAssertNil(server.requests.last?.value(forHTTPHeaderField: "If-None-Match"))

        server.setHook { _ in MockResponse(status: 200, body: Data("not a sha".utf8)) }
        do {
            _ = try await client.latestCommit(etag: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ProfileDatabaseError, .invalidResponse)
        }
    }

    func testDownloadRunsSixAtATime() async throws {
        let server = FakeGitHub()
        server.latency = 20_000_000
        var files: [String: FakeTree.Item] = [:]
        for index in 0..<20 { files["TVs/A/\(index).ir"] = irFile("\(index)") }
        let commit = server.add(files)
        let requests = files.map { IRDBClient.FileRequest(path: $0.key, sha: GitObjectHash.blob($0.value.data), size: $0.value.data.count) }
        let stored = Counter()
        try await makeClient(server).download(requests, commit: commit) { _, _ in stored.increment() }
        XCTAssertEqual(stored.value, 20)
        XCTAssertEqual(server.maxRunning, IRDBClient.concurrency)
    }

    func testDownloadStopsAtTheFirstError() async throws {
        let server = FakeGitHub()
        var files: [String: FakeTree.Item] = [:]
        for index in 0..<30 { files["TVs/A/\(index).ir"] = irFile("\(index)") }
        let commit = server.add(files)
        var requests = files.sorted { $0.key < $1.key }.map { IRDBClient.FileRequest(path: $0.key, sha: GitObjectHash.blob($0.value.data), size: $0.value.data.count) }
        requests.insert(.init(path: "TVs/missing.ir", sha: GitObjectHash.blob(Data()), size: 0), at: 0)
        let stored = Counter()
        do {
            try await makeClient(server).download(requests, commit: commit) { _, _ in stored.increment() }
            XCTFail("expected not found")
        } catch {
            XCTAssertEqual(error as? ProfileDatabaseError, .notFound)
        }
        XCTAssertLessThan(server.requests.count, 31)
    }

    // MARK: License

    /// Expected values from tools/profiles/import_flipper_irdb.py (`check_license(read_regular(...))`).
    func testLicenseCheckMatchesPython() {
        let cases: [(String, String, Bool)] = [
            ("plain", "437265617469766520436f6d6d6f6e73204c6567616c20436f64650a0a43433020312e3020556e6976657273616c0a0a72657374", true),
            ("crlf_bom", "efbbbf437265617469766520436f6d6d6f6e73204c6567616c20436f64650d0a0d0a43433020312e3020556e6976657273616c0d0a", true),
            ("leading_blank_and_spaces", "0a20090a2020437265617469766520436f6d6d6f6e73204c6567616c20436f646520200a0c0a43433020312e3020556e6976657273616c1f0a", true),
            ("fs_separators", "437265617469766520436f6d6d6f6e73204c6567616c20436f64651c43433020312e3020556e6976657273616c", true),
            ("nel", "437265617469766520436f6d6d6f6e73204c6567616c20436f6465c28543433020312e3020556e6976657273616c", true),
            ("ls_ps", "e280a8437265617469766520436f6d6d6f6e73204c6567616c20436f6465e280a9e3808043433020312e3020556e6976657273616cc2a0", true),
            ("unit_sep_is_not_a_break", "437265617469766520436f6d6d6f6e73204c6567616c20436f64651f43433020312e3020556e6976657273616c", false),
            ("zwsp_is_not_space", "e2808b437265617469766520436f6d6d6f6e73204c6567616c20436f64650a43433020312e3020556e6976657273616c", false),
            ("wrong_order", "43433020312e3020556e6976657273616c0a437265617469766520436f6d6d6f6e73204c6567616c20436f64650a", false),
            ("lowercase", "637265617469766520636f6d6d6f6e73206c6567616c20636f64650a43433020312e3020556e6976657273616c0a", false),
            ("mit", "4d4954204c6963656e73650a0a436f70797269676874202863290a", false),
            ("only_first", "437265617469766520436f6d6d6f6e73204c6567616c20436f64650a", false),
            ("invalid_utf8_line", "437265617469766520436f6d6d6f6e73204c6567616c20436f64650aff0a43433020312e3020556e6976657273616c0a", false),
            ("invalid_utf8_after", "437265617469766520436f6d6d6f6e73204c6567616c20436f64650a43433020312e3020556e6976657273616c0afffe", true),
            ("vt", "437265617469766520436f6d6d6f6e73204c6567616c20436f64650b43433020312e3020556e6976657273616c", true),
            ("cr_only", "437265617469766520436f6d6d6f6e73204c6567616c20436f64650d43433020312e3020556e6976657273616c", true),
            ("empty", "", false),
        ]
        for (name, hex, expected) in cases {
            XCTAssertEqual(IRDBLicense.isCC0(Data(hex: hex)), expected, name)
        }
        var big = Data("Creative Commons Legal Code\nCC0 1.0 Universal\n".utf8)
        big.append(Data(repeating: 0x20, count: 16 << 10))
        XCTAssertFalse(IRDBLicense.isCC0(big), "larger than 16 KiB")
        XCTAssertTrue(IRDBLicense.isCC0(cc0License))
    }

    func testReadmeNoteMatchesPython() {
        let note = { (commit: String) in
            "The upstream README states that commits prior to \(commit) are not covered by the CC0-1.0 license; see docs/ir/profiles.md."
        }
        XCTAssertEqual(IRDBLicense.note(readme: Data("> **Commits prior to [2319685](https://github.com/x/commit/2319685f2cbf0cd3f809609622cade14d24fb819) are not covered.**".utf8)), note("2319685"))
        XCTAssertEqual(IRDBLicense.note(readme: Data("commits prior to `abcdef0123` are excluded".utf8)), note("abcdef0123"))
        XCTAssertEqual(IRDBLicense.note(readme: Data(("Commits prior to " + String(repeating: "a", count: 45)).utf8)), note(String(repeating: "a", count: 40)))
        XCTAssertEqual(IRDBLicense.note(readme: Data(hex: "efbbbf436f6d6d697473207072696f7220746f205b313233343536375d")), note("1234567"))
        XCTAssertNil(IRDBLicense.note(readme: Data("Commits prior to abc12".utf8)))
        XCTAssertNil(IRDBLicense.note(readme: Data("Commits prior to ABCDEF0".utf8)))
        XCTAssertNil(IRDBLicense.note(readme: Data("nothing here".utf8)))
        XCTAssertNil(IRDBLicense.note(readme: nil))
    }

    // MARK: Live smoke test

    /// One real download of the pinned revision from GitHub, built with the real importer. Off by default:
    /// OPENPULT_NETWORK_TESTS=1. With OPENPULT_PROFILES_EXPECTED=<Python output for the pinned commit> the built
    /// files must be byte-identical to it.
    @MainActor
    func testLiveDownloadFromGitHub() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENPULT_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("set OPENPULT_NETWORK_TESTS=1 to download from GitHub")
        }
        let transport = CountingTransport(IRDBClient.makeTransport())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("irdb-live-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let builder = RecordingBuilder(PultProfileBuilder())
        let database = ProfileDatabase(directory: directory, client: IRDBClient(transport: transport), builder: builder)

        let started = Date()
        let outcome = await database.install(.pinned).value
        let seconds = Date().timeIntervalSince(started)
        guard case .installed(let info) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(info.commit, IRDBPin.commit)
        XCTAssertEqual(info.tvsTree, IRDBPin.tvsTree)
        let input = try XCTUnwrap(builder.input)
        let bytes = try input.files.reduce(0) { $0 + (try $1.load()).count }
        XCTAssertEqual(input.files.count, 398)
        XCTAssertEqual(bytes, 1_300_794)
        XCTAssertNotNil(input.licenseNote)
        let current = try XCTUnwrap(database.catalog?.directory)
        let built = try FileManager.default.subpathsOfDirectory(atPath: current.path).filter { $0.hasSuffix(".json") && $0 != "meta.json" && $0 != "manifest.json" }
        let builtBytes = try built.reduce(0) { $0 + (try Data(contentsOf: current.appendingPathComponent($1))).count }

        if let expected = environment["OPENPULT_PROFILES_EXPECTED"] {
            let expectedURL = URL(fileURLWithPath: expected)
            let names = try FileManager.default.subpathsOfDirectory(atPath: expected).filter { $0.hasSuffix(".json") }
            XCTAssertEqual(Set(built), Set(names))
            for name in names {
                XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent(name)), try Data(contentsOf: expectedURL.appendingPathComponent(name)), name)
            }
        }

        let pinnedAPI = transport.count(host: "api.github.com")
        let raw = transport.count(host: "raw.githubusercontent.com")
        let latestStarted = Date()
        let latest = await database.install(.latest).value
        let latestSeconds = Date().timeIntervalSince(latestStarted)
        print("""
            openpult live download: pinned \(input.files.count) files, \(bytes) bytes, in \(String(format: "%.1f", seconds)) s \
            (download and build); API requests \(pinnedAPI), raw requests \(raw), response bytes \(transport.bytes); \
            built \(built.count) files, \(builtBytes) bytes, counts \(info.counts); \
            latest: \(latest) in \(String(format: "%.1f", latestSeconds)) s, API requests in total \(transport.count(host: "api.github.com"))
            """)
    }
}

/// Records the input, then builds with another builder.
final class RecordingBuilder: ProfileBuilding, @unchecked Sendable {
    private let base: any ProfileBuilding
    private let lock = NSLock()
    private var recorded: ProfileBuildInput?

    init(_ base: any ProfileBuilding) {
        self.base = base
    }

    var fingerprint: String { base.fingerprint }
    var input: ProfileBuildInput? { lock.withLock { recorded } }

    func build(_ input: ProfileBuildInput) throws -> [ProfileFile] {
        lock.withLock { recorded = input }
        return try base.build(input)
    }
}

// MARK: - Helpers

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        _ = next()
    }

    /// Increments and returns the new value.
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

/// Counts real requests by host.
final class CountingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let base: HTTPTransport
    private var hosts: [String: Int] = [:]
    private(set) var bytes = 0

    init(_ base: HTTPTransport) {
        self.base = base
    }

    func count(host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return hosts[host] ?? 0
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { hosts[request.url?.host ?? "", default: 0] += 1 }
        let (data, response) = try await base.send(request)
        lock.withLock { bytes += data.count }
        return (data, response)
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
