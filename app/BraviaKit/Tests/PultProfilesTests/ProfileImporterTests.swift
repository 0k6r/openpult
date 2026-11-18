import Foundation
import XCTest
@testable import PultProfiles

/// Python semantics the port depends on, the walk order, the public API and the directory source.
final class ProfileImporterTests: XCTestCase {
    private let head = "Filetype: IR signals file\nVersion: 1\n"

    private func block(_ name: String, _ address: Int, _ command: Int) -> String {
        String(format: "name: %@\ntype: parsed\nprotocol: NEC\naddress: %02X 00 00 00\ncommand: %02X 00 00 00\n",
               name, address, command)
    }

    private func run(_ files: [(String, String)], contrib: [(String, String)] = []) throws -> ProfileBundle {
        try ProfileImporter.run(files: files.map { IRDBFile(path: $0.0, data: Data($0.1.utf8)) },
                                contrib: contrib.map { IRDBFile(path: $0.0, data: Data($0.1.utf8)) },
                                aliases: .bundled, source: ImportSource(commit: fixtureCommit))
    }

    // MARK: Python string semantics

    func testWhitespaceAndLineBreaksAreThePythonSets() {
        let spaces: Set<UInt32> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680,
                                   0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009,
                                   0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
        let breaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029]
        for value in UInt32(0)...0x3100 {
            guard let c = Unicode.Scalar(value) else { continue }
            XCTAssertEqual(Py.isSpace(c), spaces.contains(value), String(value, radix: 16))
            XCTAssertEqual(Py.isLineBreak(c), breaks.contains(value), String(value, radix: 16))
        }
    }

    func testSplitLinesLikePython() {
        XCTAssertEqual(Py.splitLines(""), [])
        XCTAssertEqual(Py.splitLines("a"), ["a"])
        XCTAssertEqual(Py.splitLines("a\n"), ["a"])
        XCTAssertEqual(Py.splitLines("\n"), [""])
        XCTAssertEqual(Py.splitLines("a\r\nb\rc\n\nd"), ["a", "b", "c", "", "d"])
        XCTAssertEqual(Py.splitLines("a\r\r\nb"), ["a", "", "b"])
        XCTAssertEqual(Py.splitLines("a\u{1C}b\u{85}c\u{2028}d\u{0B}e\u{1F}f"), ["a", "b", "c", "d", "e\u{1F}f"])
    }

    func testStringOperationsUseCodePoints() {
        // Canonically equivalent but different code points: Python keeps them apart.
        XCTAssertFalse(Py.equal("e\u{301}", "\u{E9}"))
        XCTAssertNotEqual(PyKey("e\u{301}"), PyKey("\u{E9}"))
        XCTAssertNotEqual(PyKey("\u{212A}"), PyKey("K"))
        XCTAssertTrue(Py.starts("e\u{301}x", with: "e"))
        XCTAssertEqual(Py.count("e\u{301}"), 2)
        assertScalars(Py.prefix("e\u{301}\u{301}x", 2), "e\u{301}")
        XCTAssertTrue(Py.less("Z", "a"))
        XCTAssertTrue(Py.less("\u{E9}", "\u{1F600}"))
        XCTAssertTrue(Py.less("\u{FFFF}", "\u{10000}"))   // UTF-16 order would differ
    }

    func testLowerHandlesFinalSigma() {
        assertScalars(Py.lower("\u{3A3}\u{391}\u{3A3}"), "\u{3C3}\u{3B1}\u{3C2}")
        assertScalars(Py.lower("\u{3A3}"), "\u{3C3}")
        assertScalars(Py.lower("A\u{3A3}'"), "a\u{3C2}'")
        assertScalars(Py.lower("A\u{3A3}'B"), "a\u{3C3}'b")
        // Private-use code points are never case-ignorable (Apple's tables mark some of them).
        assertScalars(Py.lower("A\u{F870}\u{3A3}"), "a\u{F870}\u{3C3}")
        assertScalars(Py.lower("A\u{3A3}\u{F870}B"), "a\u{3C2}\u{F870}b")
        assertScalars(Py.lower("\u{130}"), "i\u{307}")
        assertScalars(Py.lower("\u{1E9E}"), "\u{DF}")
    }

    func testAsciiRepr() {
        XCTAssertEqual(Py.ascii("abc"), "'abc'")
        XCTAssertEqual(Py.ascii("it's"), "\"it's\"")
        XCTAssertEqual(Py.ascii("'\""), "'\\'\"'")
        XCTAssertEqual(Py.ascii("\u{7}\t\n\r\\\u{7F}\u{E9}\u{202E}\u{1F600}"), "'\\x07\\t\\n\\r\\\\\\x7f\\xe9\\u202e\\U0001f600'")
    }

    func testDecodeDropsOneBOMAndReplacesInvalidBytes() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x41, 0xED, 0xA0, 0x80, 0xC0, 0xAF, 0xE2, 0x82]
        assertScalars(Py.decodeUTF8(Data(bytes)), "\u{FEFF}A\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}")
    }

    func testRoundHalfToEven() {
        XCTAssertEqual(Py.round(12.5), 12)
        XCTAssertEqual(Py.round(13.5), 14)
        XCTAssertEqual(Py.round(-0.5), 0)
        XCTAssertEqual(Py.floorDiv(-7, 2), -4)
        XCTAssertEqual(Py.floorDiv(7, 2), 3)
    }

    func testJSONStringEscapes() {
        assertScalars(ProfileWriter.quote("a\"b\\c\u{8}\u{C}\n\r\t\u{1}\u{7F}\u{E9}\u{2028}e\u{301}"),
                      "\"a\\\"b\\\\c\\b\\f\\n\\r\\t\\u0001\u{7F}\u{E9}\u{2028}e\u{301}\"")
        XCTAssertEqual(ProfileWriter.quote("\u{7F}\u{E9}\u{1F600}", ensureASCII: true), "\"\\u007f\\u00e9\\ud83d\\ude00\"")
    }

    func testCanonicalCommandsSortLikePython() {
        let parsed = ProfileCommand.parsed(protocol: "NEC", address: 4, command: 8)
        XCTAssertEqual(parsed.json, "{\"p\":\"NEC\",\"a\":4,\"c\":8}")
        XCTAssertEqual(parsed.canonical, "{\"a\":4,\"c\":8,\"p\":\"NEC\"}")
        let raw = ProfileCommand.raw(frequency: 38_000, duty: 33, intro: [], repeat: [500, 25_000])
        XCTAssertEqual(raw.json, "{\"raw\":{\"f\":38000,\"d\":33,\"i\":[],\"r\":[500,25000]}}")
        XCTAssertEqual(raw.canonical, "{\"raw\":{\"d\":33,\"f\":38000,\"i\":[],\"r\":[500,25000]}}")
    }

    // MARK: Aliases

    func testBundledAliases() {
        let aliases = KeyAliases.bundled
        XCTAssertEqual(aliases.keyOrder.first, "power")
        XCTAssertEqual(aliases.keyOrder.count, 50)
        XCTAssertTrue(aliases.aliases(for: "volumeUp").contains("vol+"))
        XCTAssertEqual(aliases.letterGroups.count, 2)
    }

    func testAliasesRejectDuplicatesAndBadTargets() {
        XCTAssertThrowsError(try KeyAliases(json: Data(#"{"keys": {"power": ["Power", "POWER"]}}"#.utf8)))
        XCTAssertThrowsError(try KeyAliases(json: Data(#"{"keys": {"power": ["power"]}, "letterColors": [{"a": "red"}]}"#.utf8)))
        XCTAssertThrowsError(try KeyAliases(json: Data(#"{"keys": {}}"#.utf8)))
        XCTAssertThrowsError(try KeyAliases(json: Data(#"{"keys": {"power": "power"}}"#.utf8)))
        XCTAssertThrowsError(try KeyAliases(json: Data(#"{"keys": {"power": ["x"]} "#.utf8)))
        for number in ["01", "+1", "1.", ".5", "1.e5", "-"] {
            XCTAssertThrowsError(try KeyAliases(json: Data(#"{"keys": {"power": ["x"]}, "n": \#(number)}"#.utf8)), number)
        }
        for number in ["-0", "1e400", "-0.5e-3", "10"] {
            XCTAssertNoThrow(try KeyAliases(json: Data(#"{"keys": {"power": ["x"]}, "n": \#(number)}"#.utf8)), number)
        }
        // A later value of a repeated letter replaces the earlier one, as in a Python dict.
        let aliases = try? KeyAliases(json: Data(#"{"keys": {"power": ["p"], "red": ["r"]}, "letterColors": [{"A": "nope", "a": "red"}]}"#.utf8))
        XCTAssertEqual(aliases?.letterGroups.first?.map(\.key), ["red"])
    }

    func testAliasKeyOrderFollowsTheFile() throws {
        let aliases = try KeyAliases(json: Data(#"{"keys": {"zeta": ["z"], "alpha": ["a"], "mid": ["m\u00e9"]}}"#.utf8))
        XCTAssertEqual(aliases.keyOrder, ["zeta", "alpha", "mid"])
        assertScalars(aliases.aliases(for: "mid"), ["m\u{E9}"])
    }

    // MARK: Walk order and file hygiene

    func testFilesInAFolderComeBeforeItsSubfolders() throws {
        // os.walk yields TVs/nova_X-1.ir before TVs/Nova/...: the root file names the brand "nova".
        let bundle = try run([("Nova/Nova_X-2.ir", head + block("Power", 1, 1)),
                              ("nova_X-1.ir", head + block("Power", 1, 2))])
        let index = String(decoding: filesByPath(bundle)["index.json"]!, as: UTF8.self)
        XCTAssertTrue(index.contains(#"{"id": "nova", "name": "nova""#), index)
    }

    func testHiddenDeepAndUnsafePathsAreSkipped() throws {
        let deep = (0..<8).map { "d\($0)" }.joined(separator: "/")
        let bundle = try run([
            ("Acme/.hidden.ir", head + block("Power", 1, 1)),
            (".git/x.ir", head + block("Power", 1, 2)),
            ("Acme/\(deep)/x.ir", head + block("Power", 1, 3)),
            ("Acme/\(deep)/more/y.ir", head + block("Power", 1, 4)),
            ("Acme/d0/d1/d2/d3/d4/d5/ok.ir", head + block("Power", 1, 5)),
            ("Acme/Acme_\u{202E}evil.ir", head + block("Power", 1, 6)),
            ("Acme/" + String(repeating: "x", count: 200) + ".ir", head + block("Power", 1, 7)),
            ("Acme//double.ir", head + block("Power", 1, 8)),
        ])
        let report = bundle.report
        XCTAssertEqual(report.filesSeen, 1)
        XCTAssertEqual(report.skippedFiles, ["file: folder nested too deep": 1, "file: unsafe file name": 3])
        XCTAssertEqual(report.skipExamples["file: folder nested too deep"], ["'Acme/d0/d1/d2/d3/d4/d5/d6'"])
        XCTAssertTrue(report.skipExamples["file: unsafe file name"]!.contains("'Acme/Acme_\\u202eevil.ir'"))
    }

    func testLoaderFailures() throws {
        let text = Data((head + block("Power", 1, 1)).utf8)
        let files = [
            IRDBFile(path: "Acme/link.ir") { throw IRDBFileError.notRegularFile },
            IRDBFile(path: "Acme/gone.ir") { throw IRDBFileError.unreadable("PermissionError") },
            IRDBFile(path: "Acme/big.ir", data: Data(repeating: 0x41, count: (1 << 20) + 1)),
            IRDBFile(path: "Acme/max.ir", data: text + Data(repeating: 0x20, count: (1 << 20) - text.count)),
        ]
        let bundle = try ProfileImporter.run(files: files, aliases: .bundled, source: ImportSource(commit: fixtureCommit))
        let report = bundle.report
        XCTAssertEqual(report.filesSeen, 3)   // a symlink is not counted, like os.walk + islink in Python
        XCTAssertEqual(report.skippedFiles["file: symlink or special file"], 1)
        XCTAssertEqual(report.skipExamples["file: symlink or special file"], ["Acme/link.ir"])
        XCTAssertEqual(report.skippedFiles["file: larger than 1 MiB"], 1)
        XCTAssertEqual(report.skippedFiles["file: unreadable (PermissionError)"], 1)
        XCTAssertEqual(report.skipExamples["file: unreadable (PermissionError)"], ["TVs/Acme/gone.ir"])
        XCTAssertEqual(report.filesUsed, 1)
    }

    func testOtherLoaderErrorsStopTheImport() {
        struct Damaged: Error, Equatable {}
        let files = [IRDBFile(path: "Acme/a.ir", data: Data((head + block("Power", 1, 1)).utf8)),
                     IRDBFile(path: "Acme/b.ir") { throw Damaged() }]
        XCTAssertThrowsError(try ProfileImporter.run(files: files, aliases: .bundled,
                                                     source: ImportSource(commit: fixtureCommit))) {
            XCTAssertEqual($0 as? Damaged, Damaged())
        }
    }

    func testContribSourcesArePrefixed() throws {
        let hotel = head + block("Power", 4, 8)
        let bundle = try run([("Acme/Acme_Hotel.ir", hotel)], contrib: [("Acme/Acme_Hotel2.ir", hotel)])
        let acme = String(decoding: filesByPath(bundle)["brands/acme.json"]!, as: UTF8.self)
        XCTAssertTrue(acme.contains(#""source": ["TVs/Acme/Acme_Hotel.ir","contrib/TVs/Acme/Acme_Hotel2.ir"],"#), acme)
        XCTAssertTrue(acme.contains(#""weight": 2,"#))
    }

    func testEquivalentNamesStayDistinct() throws {
        // "Café" with a precomposed and a decomposed é are different names in Python: no " #2" suffix.
        let bundle = try run([("Acme/Acme_Caf\u{E9}.ir", head + block("Power", 1, 1)),
                              ("Acme/Acme_Cafe\u{301}.ir", head + block("Power", 1, 2))])
        let acme = String(decoding: filesByPath(bundle)["brands/acme.json"]!, as: UTF8.self)
        let names = acme.components(separatedBy: "\n").filter { $0.hasPrefix("    \"name\": ") }
        assertScalars(names.sorted(by: Py.less), ["    \"name\": \"Acme TV (Cafe\u{301})\",",
                                                  "    \"name\": \"Acme TV (Caf\u{E9})\","])
    }

    func testKelvinSignIsNotKaseikyo() {
        let text = head + "name: Power\ntype: parsed\nprotocol: \u{212A}aseikyo\naddress: 01 00 00 00\ncommand: 01 00 00 00\n"
        let (buttons, errors) = IRFileParser.parseIRText(text)
        XCTAssertTrue(buttons.isEmpty)
        XCTAssertEqual(errors, ["parsed: unknown protocol": 1])
    }

    // MARK: Arguments

    func testArgumentsAreChecked() {
        let files = [IRDBFile(path: "Acme/a.ir", data: Data((head + block("Power", 1, 1)).utf8))]
        XCTAssertThrowsError(try ProfileImporter.run(files: files, aliases: .bundled, source: ImportSource(commit: "abc"))) {
            XCTAssertEqual($0 as? ProfileImportError, .invalidCommit("abc"))
        }
        XCTAssertThrowsError(try ProfileImporter.run(files: files, aliases: .bundled,
                                                     source: ImportSource(commit: String(repeating: "A", count: 40))))
        for url in ["http://example.com", "https://example.com/x; rm -rf ~", "https://", "https://a/", "https://a/b c"] {
            XCTAssertThrowsError(try ProfileImporter.run(files: files, aliases: .bundled,
                                                         source: ImportSource(commit: fixtureCommit, url: url)), url)
        }
        XCTAssertNoThrow(try ProfileImporter.run(files: files, aliases: .bundled,
                                                 source: ImportSource(commit: fixtureCommit, url: "https://a.b/c-d/e_f.g")))
        XCTAssertThrowsError(try ProfileImporter.run(files: files, aliases: .bundled,
                                                     source: ImportSource(commit: fixtureCommit, url: "https://a.b\n")))
        XCTAssertThrowsError(try ProfileImporter.run(files: files + files, aliases: .bundled,
                                                     source: ImportSource(commit: fixtureCommit))) {
            XCTAssertEqual($0 as? ProfileImportError, .duplicatePath("Acme/a.ir"))
        }
    }

    func testEmptyImport() throws {
        let bundle = try ProfileImporter.run(files: [], aliases: .bundled, source: ImportSource(commit: fixtureCommit, licenseNote: "\u{0}"))
        let files = filesByPath(bundle)
        XCTAssertEqual(String(decoding: files["power_scan.json"]!, as: UTF8.self), "[]\n")
        XCTAssertEqual(String(decoding: files["index.json"]!, as: UTF8.self), """
            {
              "schema": 1,
              "source": {"db": "Flipper-IRDB", "url": "https://github.com/Lucaslhm/Flipper-IRDB", "commit": "\(fixtureCommit)", "license": "CC0-1.0"},
              "brands": [

              ]
            }

            """)
    }

    func testCancellation() async throws {
        let text = Data((head + block("Power", 1, 1)).utf8)
        let loads = Counter()
        // The 10th file cancels the task: the import stops before the 11th is read.
        let files = (0..<50).map { i in
            IRDBFile(path: String(format: "Acme/%02d.ir", i)) {
                loads.increment()
                if i == 9 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return text
            }
        }
        let task = Task {
            try ProfileImporter.run(files: files, aliases: .bundled, source: ImportSource(commit: fixtureCommit))
        }
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(loads.value, 10)
    }

    func testFingerprintCoversVersionAndAliases() throws {
        let bundled = ProfileImporter.fingerprint(aliases: .bundled)
        XCTAssertTrue(bundled.hasPrefix("importer-\(ProfileImporter.version)-aliases-"), bundled)
        let a = try KeyAliases(json: Data(#"{"keys": {"power": ["p"]}}"#.utf8))
        let b = try KeyAliases(json: Data(#"{"keys": {"power": ["pwr"]}}"#.utf8))
        XCTAssertNotEqual(ProfileImporter.fingerprint(aliases: a), ProfileImporter.fingerprint(aliases: b))
        XCTAssertEqual(a.digest, try KeyAliases(json: Data(#"{"keys": {"power": ["p"]}}"#.utf8)).digest)
        XCTAssertEqual(a.digest.count, 16)
    }

    // MARK: License

    func testLicenseCheckAndNote() {
        XCTAssertTrue(ProfileImporter.checkLicense(Data("\u{FEFF}\n  Creative Commons Legal Code\n\nCC0 1.0 Universal\nrest".utf8)))
        XCTAssertFalse(ProfileImporter.checkLicense(Data("All rights reserved\n".utf8)))
        XCTAssertFalse(ProfileImporter.checkLicense(Data(("Creative Commons Legal Code\nCC0 1.0 Universal\n"
                                                          + String(repeating: " ", count: 16 << 10)).utf8)))
        XCTAssertEqual(ProfileImporter.licenseNote(readme: Data("Commits prior to [`2319685`](x) are not".utf8)),
                       "The upstream README states that commits prior to 2319685 are not covered by the CC0-1.0 "
                       + "license; see docs/ir/profiles.md.")
        XCTAssertEqual(ProfileImporter.licenseNote(readme: Data("commits prior to abc12 and Commits prior to deadbeef1".utf8)),
                       "The upstream README states that commits prior to deadbeef1 are not covered by the CC0-1.0 "
                       + "license; see docs/ir/profiles.md.")
        XCTAssertNil(ProfileImporter.licenseNote(readme: Data("Commits prior to 123456 only".utf8)))
    }

    // MARK: Directory source

    func testDirectorySourceSkipsSymlinksLikeThePythonImporter() throws {
        let manager = FileManager.default
        let tmp = manager.temporaryDirectory.appendingPathComponent("pult-irdb-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: tmp) }
        let tvs = tmp.appendingPathComponent("TVs/Acme")
        try manager.createDirectory(at: tvs, withIntermediateDirectories: true)
        try Data((head + block("Power", 4, 8)).utf8).write(to: tvs.appendingPathComponent("Acme_Hotel.ir"))
        let outside = tmp.appendingPathComponent("outside.ir")
        try Data((head + block("Power", 4, 9)).utf8).write(to: outside)
        try manager.createSymbolicLink(at: tvs.appendingPathComponent("Acme_Link.ir"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: tmp.appendingPathComponent("TVs/Loop"), withDestinationURL: tmp)
        try manager.createDirectory(at: tmp.appendingPathComponent("TVs/.git"), withIntermediateDirectories: true)

        let db = DirectoryIRDBSource(root: tmp)
        XCTAssertEqual(try db.files().map(\.path), ["Acme/Acme_Hotel.ir", "Acme/Acme_Link.ir"])
        let bundle = try ProfileImporter.run(files: db.files(), aliases: .bundled, source: ImportSource(commit: fixtureCommit))
        XCTAssertEqual(bundle.report.skippedFiles, ["file: symlink or special file": 1])
        XCTAssertEqual(bundle.report.filesUsed, 1)
        XCTAssertNil(db.license())
        XCTAssertNil(db.licenseNote())

        let linked = tmp.appendingPathComponent("linked")
        try manager.createDirectory(at: linked, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: linked.appendingPathComponent("TVs"), withDestinationURL: tmp.appendingPathComponent("TVs"))
        XCTAssertThrowsError(try DirectoryIRDBSource(root: linked).files())   // TVs/ itself must not be a symlink
        XCTAssertThrowsError(try DirectoryIRDBSource(root: tvs).files())
    }

    func testDirectorySourceSkipsWhatItCannotRead() throws {
        let manager = FileManager.default
        let tmp = manager.temporaryDirectory.appendingPathComponent("pult-irdb-\(UUID().uuidString)")
        let locked = tmp.appendingPathComponent("TVs/Locked")
        let secret = tmp.appendingPathComponent("TVs/Acme/Acme_Secret.ir")
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path)
            try? manager.removeItem(at: tmp)
        }
        try manager.createDirectory(at: locked, withIntermediateDirectories: true)
        try manager.createDirectory(at: secret.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((head + block("Power", 6, 1)).utf8).write(to: locked.appendingPathComponent("x.ir"))
        try Data((head + block("Power", 6, 2)).utf8).write(to: secret)
        try Data((head + block("Power", 6, 3)).utf8).write(to: tmp.appendingPathComponent("TVs/Acme/Acme_Open.ir"))
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
        if manager.isReadableFile(atPath: secret.path) {
            throw XCTSkip("running with permissions that ignore file modes")
        }
        let files = try DirectoryIRDBSource(root: tmp).files()   // os.walk skips the folder it cannot list
        XCTAssertEqual(files.map(\.path), ["Acme/Acme_Open.ir", "Acme/Acme_Secret.ir"])
        let report = try ProfileImporter.run(files: files, aliases: .bundled, source: ImportSource(commit: fixtureCommit)).report
        XCTAssertEqual(report.skippedFiles, ["file: unreadable (PermissionError)": 1])
        XCTAssertEqual(report.filesSeen, 2)
        XCTAssertEqual(report.filesUsed, 1)
    }

    func testDirectorySourceStopsAtTheDepthLimit() throws {
        let manager = FileManager.default
        let tmp = manager.temporaryDirectory.appendingPathComponent("pult-irdb-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: tmp) }
        var deep = tmp.appendingPathComponent("TVs/Deep")
        for i in 0..<10 {
            deep.appendPathComponent("d\(i)")
        }
        try manager.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data((head + block("Power", 5, 1)).utf8).write(to: deep.appendingPathComponent("x.ir"))
        let files = try DirectoryIRDBSource(root: tmp).files()
        XCTAssertEqual(files.map(\.path), ["Deep/d0/d1/d2/d3/d4/d5/d6/d7"])
        let report = try ProfileImporter.run(files: files, aliases: .bundled, source: ImportSource(commit: fixtureCommit)).report
        XCTAssertEqual(report.skippedFiles, ["file: folder nested too deep": 1])
        XCTAssertEqual(report.skipExamples["file: folder nested too deep"], ["'Deep/d0/d1/d2/d3/d4/d5/d6'"])
    }
}

/// A thread-safe counter for loaders (they are `@Sendable`).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.lock(); defer { lock.unlock() }; return count }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
