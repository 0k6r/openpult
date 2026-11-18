import Foundation
import XCTest
@testable import BraviaKit

final class GitObjectHashTests: XCTestCase {
    private let hello = "ce013625030ba8dba906f756967f9e9ca394464a"
    private let empty = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
    private let script = "1a2485251c33a70432394c93fb89330ef214bfc9"

    func testBlobIDsMatchGit() {
        XCTAssertEqual(GitObjectHash.blob(Data()), empty)
        XCTAssertEqual(GitObjectHash.blob(Data("hello\n".utf8)), hello)
        XCTAssertEqual(GitObjectHash.blob(Data("#!/bin/sh\n".utf8)), script)
        XCTAssertEqual(GitObjectHash.blob(Data("what is up, doc?".utf8)), "bd9dbf5aae1a3862dd1526723246b20206e5fc37")
    }

    func testTreeIDsMatchGitMktree() throws {
        XCTAssertEqual(try GitObjectHash.tree([]), "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
        let sub = try GitObjectHash.tree([.init(name: "b.ir", kind: .blob(executable: false), sha: hello)])
        XCTAssertEqual(sub, "8f5f673d7b65cffb36baea14edc1dd142f6a10f2")
        // `git mktree` of these entries; git orders them a-, a.b, a (tree, sorted as "a/"), a0, link, "Ä é.ir".
        let entries: [GitObjectHash.TreeEntry] = [
            .init(name: "\u{C4} \u{E9}.ir", kind: .blob(executable: false), sha: empty),
            .init(name: "link", kind: .symlink, sha: hello),
            .init(name: "a0", kind: .blob(executable: false), sha: empty),
            .init(name: "a", kind: .tree, sha: sub),
            .init(name: "a.b", kind: .blob(executable: false), sha: hello),
            .init(name: "a-", kind: .blob(executable: true), sha: script),
        ]
        XCTAssertEqual(try GitObjectHash.tree(entries), "827c0debb6cae741f4ee835f5caf0ff98da3ca16")
        XCTAssertEqual(try GitObjectHash.tree(entries.reversed()), "827c0debb6cae741f4ee835f5caf0ff98da3ca16")
    }

    func testCanonicallyEquivalentNamesStayDistinct() throws {
        // "é" precomposed and decomposed are different git names (and different ids).
        let precomposed = try GitObjectHash.tree([.init(name: "\u{E9}", kind: .blob(executable: false), sha: empty)])
        let decomposed = try GitObjectHash.tree([.init(name: "e\u{301}", kind: .blob(executable: false), sha: empty)])
        XCTAssertNotEqual(precomposed, decomposed)
        XCTAssertNoThrow(try GitObjectHash.tree([
            .init(name: "\u{E9}", kind: .blob(executable: false), sha: empty),
            .init(name: "e\u{301}", kind: .blob(executable: false), sha: empty),
        ]))
    }

    func testMalformedEntriesAreRejected() {
        XCTAssertThrowsError(try GitObjectHash.tree([.init(name: "a", kind: .tree, sha: "XYZ")]))
        XCTAssertThrowsError(try GitObjectHash.tree([.init(name: "a", kind: .tree, sha: hello.uppercased())]))
        XCTAssertThrowsError(try GitObjectHash.tree([.init(name: "a/b", kind: .blob(executable: false), sha: hello)]))
        XCTAssertThrowsError(try GitObjectHash.tree([.init(name: "..", kind: .tree, sha: hello)]))
        XCTAssertThrowsError(try GitObjectHash.tree([.init(name: "", kind: .tree, sha: hello)]))
        XCTAssertThrowsError(try GitObjectHash.tree([
            .init(name: "a", kind: .blob(executable: false), sha: hello),
            .init(name: "a", kind: .tree, sha: hello),
        ]))
        XCTAssertTrue(GitObjectHash.isSHA(hello))
        XCTAssertFalse(GitObjectHash.isSHA(String(hello.dropLast())))
        XCTAssertFalse(GitObjectHash.isSHA(hello + "0"))
    }

    /// The pinned tree SHA from a local Flipper-IRDB checkout (OPENPULT_IRDB=<clone>): the Merkle code agrees with git.
    func testPinnedTreeMatchesACheckout() throws {
        guard let path = ProcessInfo.processInfo.environment["OPENPULT_IRDB"] else {
            throw XCTSkip("set OPENPULT_IRDB to a Flipper-IRDB checkout of \(IRDBPin.commit)")
        }
        let tvs = URL(fileURLWithPath: path).appendingPathComponent("TVs")
        XCTAssertEqual(try Self.treeID(of: tvs), IRDBPin.tvsTree)
    }

    /// The git tree id of a folder on disk (file contents as they are, executable bits, symlinks).
    static func treeID(of directory: URL) throws -> String {
        let fm = FileManager.default
        var entries: [GitObjectHash.TreeEntry] = []
        for name in try fm.contentsOfDirectory(atPath: directory.path) where name != ".git" {
            let url = directory.appendingPathComponent(name)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?:
                entries.append(.init(name: name, kind: .tree, sha: try treeID(of: url)))
            case .typeSymbolicLink?:
                let target = try fm.destinationOfSymbolicLink(atPath: url.path)
                entries.append(.init(name: name, kind: .symlink, sha: GitObjectHash.blob(Data(target.utf8))))
            default:
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                let sha = GitObjectHash.blob(try Data(contentsOf: url))
                entries.append(.init(name: name, kind: .blob(executable: permissions & 0o100 != 0), sha: sha))
            }
        }
        return try GitObjectHash.tree(entries)
    }
}
