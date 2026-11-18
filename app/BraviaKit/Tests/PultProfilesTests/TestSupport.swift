import Foundation
import XCTest
@testable import PultProfiles

enum Paths {
    /// The repository root, found from this file (app/BraviaKit/Tests/PultProfilesTests/TestSupport.swift).
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    static let fixtures = root.appendingPathComponent("tools/profiles/fixtures")
    static let fixtureDB = fixtures.appendingPathComponent("irdb")
    static let golden = fixtures.appendingPathComponent("expected")
    static let goldenReport = fixtures.appendingPathComponent("expected-report.json")
    static let vectors = root.appendingPathComponent("testdata/profile_import_vectors.json")
}

/// The commit the fixture golden files were generated with.
let fixtureCommit = "0123456789abcdef0123456789abcdef01234567"

/// Asserts that two strings have the same code points (Swift's `==` would accept canonically equivalent ones).
func assertScalars(_ actual: String, _ expected: String, _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(actual.utf8.elementsEqual(expected.utf8),
                  "\(message()): got \(Py.ascii(actual)), expected \(Py.ascii(expected))", file: file, line: line)
}

func assertScalars(_ actual: [String], _ expected: [String], _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    let same = actual.count == expected.count && zip(actual, expected).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    XCTAssertTrue(same, "\(message()): got \(actual.map(Py.ascii)), expected \(expected.map(Py.ascii))",
                  file: file, line: line)
}

/// A command in the JSON form of the generated files.
func command(_ any: Any) -> ProfileCommand {
    let object = any as! [String: Any]
    if let raw = object["raw"] as? [String: Any] {
        return .raw(frequency: raw["f"] as! Int, duty: raw["d"] as! Int, intro: raw["i"] as! [Int],
                    repeat: raw["r"] as! [Int])
    }
    return .parsed(protocol: object["p"] as! String, address: object["a"] as! Int, command: object["c"] as! Int)
}

/// Generated files as {path: data}.
func filesByPath(_ bundle: ProfileBundle) -> [String: Data] {
    Dictionary(uniqueKeysWithValues: bundle.files.map { ($0.path, $0.data) })
}

/// The JSON value of `data` as Foundation-style `Any` ([String: Any], [Any], String, Int, Double, Bool, NSNull).
/// JSONDecoder keeps strings exact; JSONSerialization drops a leading U+FEFF from strings.
func jsonObject(_ data: Data) throws -> Any {
    try JSONDecoder().decode(AnyJSON.self, from: data).value
}

private struct AnyJSON: Decodable {
    let value: Any

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var items: [Any] = []
            while !array.isAtEnd {
                items.append(try array.decode(AnyJSON.self).value)
            }
            value = items
        } else if let object = try? decoder.container(keyedBy: Key.self) {
            var items: [String: Any] = [:]
            for key in object.allKeys {
                items[key.stringValue] = try object.decode(AnyJSON.self, forKey: key).value
            }
            value = items
        } else {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                value = NSNull()
            } else if let bool = try? single.decode(Bool.self) {
                value = bool
            } else if let int = try? single.decode(Int.self) {
                value = int
            } else if let double = try? single.decode(Double.self) {
                value = double
            } else {
                value = try single.decode(String.self)
            }
        }
    }
}

/// Compares a Swift report with the subset of the Python report that gen_import_vectors.py stores.
func assertReport(_ report: ImportReport, _ expected: [String: Any], _ label: String,
                  file: StaticString = #filePath, line: UInt = #line) {
    func ints(_ key: String) -> [String: Int] { expected[key] as! [String: Int] }
    XCTAssertEqual(report.filesSeen, expected["files_seen"] as? Int, "\(label) files_seen", file: file, line: line)
    XCTAssertEqual(report.filesUsed, expected["files_used"] as? Int, "\(label) files_used", file: file, line: line)
    XCTAssertEqual(report.brands, expected["brands"] as? Int, "\(label) brands", file: file, line: line)
    XCTAssertEqual(report.profiles, expected["profiles"] as? Int, "\(label) profiles", file: file, line: line)
    XCTAssertEqual(report.buttonsIn, ints("buttons_in"), "\(label) buttons_in", file: file, line: line)
    XCTAssertEqual(report.codesOut, ints("codes_out"), "\(label) codes_out", file: file, line: line)
    XCTAssertEqual(report.duplicatesDropped, expected["duplicates_dropped"] as? Int, "\(label) duplicates",
                   file: file, line: line)
    XCTAssertEqual(report.skippedFiles, ints("skipped_files"), "\(label) skipped_files", file: file, line: line)
    XCTAssertEqual(report.skippedCodes, ints("skipped_codes"), "\(label) skipped_codes", file: file, line: line)
    XCTAssertEqual(report.recovered, ints("recovered"), "\(label) recovered", file: file, line: line)
    let examples = expected["skip_examples"] as! [String: [String]]
    XCTAssertEqual(Set(report.skipExamples.keys), Set(examples.keys), "\(label) skip_examples", file: file, line: line)
    for (reason, places) in examples {
        assertScalars(report.skipExamples[reason] ?? [], places, "\(label) examples of \(reason)", file: file, line: line)
    }
    let protocols = expected["protocols"] as! [[Any]]
    XCTAssertEqual(report.protocols, Dictionary(uniqueKeysWithValues: protocols.map { ($0[0] as! String, $0[1] as! Int) }),
                   "\(label) protocols", file: file, line: line)
    XCTAssertEqual(report.powerScanCodes, expected["power_scan_codes"] as? Int, "\(label) power_scan", file: file, line: line)
    let top = expected["top_brands"] as! [[Any]]
    assertScalars(report.topBrands.map(\.name), top.map { $0[0] as! String }, "\(label) top_brands", file: file, line: line)
    XCTAssertEqual(report.topBrands.map(\.profiles), top.map { $0[1] as! Int }, "\(label) top_brands", file: file, line: line)
    let names = expected["name_stats"] as! [[Any]]
    XCTAssertEqual(report.nameStats.count, names.count, "\(label) name_stats", file: file, line: line)
    for (got, want) in zip(report.nameStats, names) {
        assertScalars([got.name, got.example, got.target], [want[0] as! String, want[2] as! String, want[3] as! String],
                      "\(label) name_stats", file: file, line: line)
        XCTAssertEqual(got.files, want[1] as? Int, "\(label) name_stats \(Py.ascii(got.name))", file: file, line: line)
    }
}

/// Compares generated files with expected ones byte for byte.
func assertFiles(_ actual: [String: Data], _ expected: [String: Data], _ label: String,
                 file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(Set(actual.keys), Set(expected.keys), "\(label): file names", file: file, line: line)
    for (path, data) in expected.sorted(by: { $0.key < $1.key }) {
        guard let got = actual[path] else { continue }
        if got != data {
            let a = Py.decodeUTF8(got).components(separatedBy: "\n"), b = Py.decodeUTF8(data).components(separatedBy: "\n")
            let index = (0..<min(a.count, b.count)).first { !a[$0].utf8.elementsEqual(b[$0].utf8) } ?? min(a.count, b.count)
            XCTFail("\(label): \(path) differs at line \(index + 1):\n  swift:  \(index < a.count ? Py.ascii(a[index]) : "<end>")"
                    + "\n  python: \(index < b.count ? Py.ascii(b[index]) : "<end>")", file: file, line: line)
        }
    }
}

/// {relative path: data} of index.json, brands/*.json and power_scan.json in a profiles folder.
func readProfilesFolder(_ dir: URL) throws -> [String: Data] {
    var out: [String: Data] = [:]
    for name in ["index.json", "power_scan.json"] {
        out[name] = try Data(contentsOf: dir.appendingPathComponent(name))
    }
    let brands = dir.appendingPathComponent("brands")
    for name in try FileManager.default.contentsOfDirectory(atPath: brands.path) where name.hasSuffix(".json") {
        out["brands/\(name)"] = try Data(contentsOf: brands.appendingPathComponent(name))
    }
    return out
}
