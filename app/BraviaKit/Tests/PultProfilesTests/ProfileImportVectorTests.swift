import Foundation
import XCTest
@testable import PultProfiles

/// testdata/profile_import_vectors.json: inputs and outputs of the Python importer, written by
/// tools/profiles/gen_import_vectors.py.
final class ProfileImportVectorTests: XCTestCase {
    private static let vectors: [String: Any]? = {
        guard let data = try? Data(contentsOf: Paths.vectors) else { return nil }
        return (try? jsonObject(data)) as? [String: Any]
    }()

    private func cases(_ name: String, minimum: Int = 20) -> [[String: Any]] {
        guard let vectors = Self.vectors else {
            XCTFail("cannot read \(Paths.vectors.path); run python3 -I tools/profiles/gen_import_vectors.py")
            return []
        }
        let list = vectors[name] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(list.count, minimum, "too few \(name) vectors")
        return list
    }

    private func buttons(_ any: Any) -> [Button] {
        (any as! [[Any]]).map { ($0[0] as! String, command($0[1])) }
    }

    private func assertButtons(_ actual: [Button], _ expected: [Button], _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        assertScalars(actual.map(\.name), expected.map(\.name), "\(label) names", file: file, line: line)
        assertScalars(actual.map(\.cmd.json), expected.map(\.cmd.json), "\(label) commands", file: file, line: line)
    }

    func testNormalizeName() {
        for (i, v) in cases("normalize_name").enumerated() {
            assertScalars(ProfileNames.normalizeName(v["in"] as! String), v["out"] as! String, "normalize_name #\(i)")
        }
    }

    func testCleanText() {
        for (i, v) in cases("clean_text").enumerated() {
            assertScalars(ProfileNames.cleanText(v["in"] as! String, limit: v["limit"] as! Int), v["out"] as! String,
                          "clean_text #\(i)")
        }
    }

    func testSlugify() {
        for (i, v) in cases("slugify").enumerated() {
            assertScalars(ProfileNames.slugify(v["in"] as! String), v["out"] as! String, "slugify #\(i)")
        }
    }

    func testBrandOf() {
        for (i, v) in cases("brand_of").enumerated() {
            assertScalars(ProfileNames.brandOf(v["in"] as! String), v["out"] as! String, "brand_of #\(i)")
        }
    }

    func testLooksLikeModel() {
        for (i, v) in cases("looks_like_model").enumerated() {
            let token = v["in"] as! String
            XCTAssertEqual(ProfileNames.looksLikeModel(token), v["out"] as! Bool, "looks_like_model #\(i) \(Py.ascii(token))")
        }
    }

    func testFileLabel() {
        for (i, v) in cases("file_label").enumerated() {
            let (models, label) = ProfileNames.fileLabel(v["rel"] as! String, brand: v["brand"] as! String)
            assertScalars(models, v["models"] as! [String], "file_label #\(i) models")
            assertScalars(label, v["label"] as! String, "file_label #\(i) label")
        }
    }

    func testProfileName() {
        for (i, v) in cases("profile_name").enumerated() {
            let name = ProfileNames.profileName(brand: v["brand"] as! String, models: v["models"] as! [String],
                                                label: v["label"] as! String)
            assertScalars(name, v["out"] as! String, "profile_name #\(i)")
        }
    }

    func testNormalizeRaw() {
        for (i, v) in cases("normalize_raw").enumerated() {
            let result = RawNormalizer.normalizeRaw(frequency: v["f"] as! Int, dutyCycle: (v["duty"] as? Double) ?? Double(v["duty"] as! Int),
                                                    data: v["data"] as! [Int])
            switch result {
            case .success(let cmd):
                XCTAssertTrue(v["reason"] is NSNull, "normalize_raw #\(i): expected \(v["reason"]!), got \(cmd.json)")
                if !(v["cmd"] is NSNull) {
                    assertScalars(cmd.json, command(v["cmd"]!).json, "normalize_raw #\(i)")
                }
            case .failure(let reason):
                XCTAssertEqual(reason.text, v["reason"] as? String, "normalize_raw #\(i)")
            }
        }
    }

    func testParseIRText() {
        for (i, v) in cases("parse_ir_text").enumerated() {
            let (got, errors) = IRFileParser.parseIRText(v["text"] as! String)
            assertButtons(got, buttons(v["buttons"]!), "parse_ir_text #\(i)")
            XCTAssertEqual(errors, v["errors"] as! [String: Int], "parse_ir_text #\(i) errors")
        }
    }

    func testMapButtons() {
        for (i, v) in cases("map_buttons").enumerated() {
            let mapped = ButtonMapper.mapButtons(buttons(v["buttons"]!), aliases: .bundled)
            let keys = v["keys"] as! [[Any]]
            assertScalars(mapped.keys.map(\.key), keys.map { $0[0] as! String }, "map_buttons #\(i) keys")
            assertScalars(mapped.keys.map(\.cmd.json), keys.map { command($0[1]).json }, "map_buttons #\(i) key codes")
            assertButtons(mapped.extra, buttons(v["extra"]!), "map_buttons #\(i) extra")
            XCTAssertEqual(mapped.dropped, v["dropped"] as! Int, "map_buttons #\(i) dropped")
        }
    }

    func testBuildProfiles() {
        for (i, v) in cases("build_profiles").enumerated() {
            let files = (v["files"] as! [[String: Any]]).map { f in
                FileEntry(source: f["source"] as! String,
                          keys: (f["keys"] as! [[Any]]).map { ($0[0] as! String, command($0[1])) },
                          extra: buttons(f["extra"]!), models: f["models"] as! [String], label: f["label"] as! String)
            }
            let profiles = ProfileBuilder.buildProfiles(brandID: v["brand_id"] as! String, brand: v["brand"] as! String,
                                                        files: files, keyOrder: KeyAliases.bundled.keyOrder)
            assertFiles(["brand.json": Data(ProfileWriter.formatProfiles(profiles).utf8)],
                        ["brand.json": Data((v["out"] as! String).utf8)], "build_profiles #\(i)")
        }
    }

    func testImportTrees() throws {
        func files(_ any: Any) -> [IRDBFile] {
            (any as! [[String: Any]]).map { f in
                var data = (f["text"] as? String).map { Data($0.utf8) } ?? Data(base64Encoded: f["base64"] as! String)!
                if let size = f["pad_to"] as? Int {
                    data += Data(repeating: 0x20, count: size - data.count)   // large files are stored as a recipe
                }
                return IRDBFile(path: f["path"] as! String, data: data)
            }
        }
        for (i, v) in cases("import_tree").enumerated() {
            let note = (v["license_note"] as? String) ?? ProfileImporter.licenseNote(readme: Data((v["readme"] as! String).utf8))
            let source = ImportSource(commit: fixtureCommit, url: v["url"] as! String, licenseNote: note)
            let bundle = try ProfileImporter.run(files: files(v["files"]!), contrib: files(v["contrib"]!),
                                                 aliases: .bundled, source: source)
            let expected = (v["out"] as! [String: String]).mapValues { Data($0.utf8) }
            assertFiles(filesByPath(bundle), expected, "import_tree #\(i)")
            assertReport(bundle.report, v["report"] as! [String: Any], "import_tree #\(i)")
        }
    }
}
