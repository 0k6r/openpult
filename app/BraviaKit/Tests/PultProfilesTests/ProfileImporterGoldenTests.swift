import Foundation
import XCTest
@testable import PultProfiles

/// The Swift importer against the Python reference: fixtures (tools/profiles/fixtures/expected, written by
/// tools/profiles/gen_import_vectors.py) and, when configured, a full Flipper-IRDB clone.
final class ProfileImporterGoldenTests: XCTestCase {
    private func importFixtures() throws -> ProfileBundle {
        let db = DirectoryIRDBSource(root: Paths.fixtureDB)
        XCTAssertTrue(ProfileImporter.checkLicense(try XCTUnwrap(db.license())))
        let source = ImportSource(commit: fixtureCommit, licenseNote: db.licenseNote())
        return try ProfileImporter.run(files: db.files(), aliases: .bundled, source: source)
    }

    func testFixtureImportMatchesPythonGolden() throws {
        let bundle = try importFixtures()
        assertFiles(filesByPath(bundle), try readProfilesFolder(Paths.golden), "fixtures")
    }

    func testFixtureReportMatchesPython() throws {
        let bundle = try importFixtures()
        let expected = try jsonObject(Data(contentsOf: Paths.goldenReport)) as! [String: Any]
        assertReport(bundle.report, expected, "fixtures")
        XCTAssertEqual(bundle.report.commit, fixtureCommit)
        XCTAssertEqual(bundle.report.sizeBytes, bundle.files.reduce(0) { $0 + $1.data.count })
    }

    func testFixtureBundleLayout() throws {
        let bundle = try importFixtures()
        let paths = bundle.files.map(\.path)
        XCTAssertEqual(paths.suffix(2), ["index.json", "power_scan.json"])
        let index = try jsonObject(filesByPath(bundle)["index.json"]!) as! [String: Any]
        let brandFiles = (index["brands"] as! [[String: Any]]).map { $0["file"] as! String }
        XCTAssertEqual(Array(paths.dropLast(2)), brandFiles)   // in brand id order, as Python writes them

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pult-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try bundle.write(to: dir)
        assertFiles(try readProfilesFolder(dir), filesByPath(bundle), "written bundle")
    }

    /// The fixture output is pinned: if it changes for the same input, bump `ProfileImporter.version` (stored
    /// databases are rebuilt only when the fingerprint changes), then update the digest here.
    func testFixtureOutputIsPinnedToTheImporterVersion() throws {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for (path, data) in filesByPath(try importFixtures()).sorted(by: { $0.key < $1.key }) {
            for byte in Data(path.utf8) + [0] + data {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
        }
        XCTAssertEqual("\(ProfileImporter.version):\(String(hash, radix: 16))", "1:89d0c1b1006ffe69",
                       "the generated files changed: bump ProfileImporter.version and update this pin")
    }

    func testReimportIsIdentical() throws {
        XCTAssertEqual(filesByPath(try importFixtures()), filesByPath(try importFixtures()))
    }

    func testInputOrderDoesNotMatter() throws {
        let db = DirectoryIRDBSource(root: Paths.fixtureDB)
        let files = try db.files()
        let source = ImportSource(commit: fixtureCommit, licenseNote: db.licenseNote())
        let forward = try ProfileImporter.run(files: files, aliases: .bundled, source: source)
        let backward = try ProfileImporter.run(files: files.reversed(), aliases: .bundled, source: source)
        XCTAssertEqual(filesByPath(forward), filesByPath(backward))
        XCTAssertEqual(forward.report, backward.report)
    }

    /// OPENPULT_IRDB = a Flipper-IRDB checkout, OPENPULT_PROFILES_EXPECTED = the Python importer's output for it.
    func testFullCloneMatchesPython() throws {
        let env = ProcessInfo.processInfo.environment
        guard let irdb = env["OPENPULT_IRDB"], !irdb.isEmpty,
              let expectedPath = env["OPENPULT_PROFILES_EXPECTED"], !expectedPath.isEmpty
        else {
            throw XCTSkip("set OPENPULT_IRDB and OPENPULT_PROFILES_EXPECTED to compare with a full Python import")
        }
        let expectedDir = URL(fileURLWithPath: expectedPath)
        let expected = try readProfilesFolder(expectedDir)
        let index = try jsonObject(XCTUnwrap(expected["index.json"])) as! [String: Any]
        let commit = try XCTUnwrap((index["source"] as? [String: Any])?["commit"] as? String)

        let db = DirectoryIRDBSource(root: URL(fileURLWithPath: irdb))
        XCTAssertTrue(ProfileImporter.checkLicense(try XCTUnwrap(db.license())), "LICENSE is not CC0")
        // Like the Python importer's default --contrib: tools/profiles/contrib when it has a TVs/ folder.
        let contribRoot = Paths.root.appendingPathComponent("tools/profiles/contrib")
        var isDirectory: ObjCBool = false
        let hasContrib = FileManager.default.fileExists(atPath: contribRoot.appendingPathComponent("TVs").path,
                                                        isDirectory: &isDirectory) && isDirectory.boolValue
        let contrib = hasContrib ? try DirectoryIRDBSource(root: contribRoot).files() : []
        let start = Date()
        let bundle = try ProfileImporter.run(files: db.files(), contrib: contrib, aliases: .bundled,
                                             source: ImportSource(commit: commit, licenseNote: db.licenseNote()))
        let seconds = Date().timeIntervalSince(start)
        assertFiles(filesByPath(bundle), expected, "full clone")
        let report = bundle.report
        print("full clone: \(report.filesUsed) of \(report.filesSeen) files, \(report.brands) brands, "
              + "\(report.profiles) profiles, \(report.codes) codes, \(report.sizeBytes) bytes in "
              + String(format: "%.2f s", seconds))
        XCTAssertGreaterThan(report.profiles, 100)
    }
}
