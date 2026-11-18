import Foundation

/// Button-name aliases (Resources/key_aliases.json, shared with tools/profiles/import_flipper_irdb.py).
///
/// Every name is stored normalized (`normalize_name`). The order of `keys` in the file is the order of the keys in
/// the generated profiles.
public struct KeyAliases: Sendable {
    /// App keys (`RemoteKey.rawValue`) in file order.
    public let keyOrder: [String]
    /// Normalized aliases per key, in priority order.
    let byKey: [PyKey: [String]]
    /// Letter buttons that become color keys when the whole group is present: (normalized letter, key) pairs.
    let letterGroups: [[(letter: String, key: String)]]
    /// Reviewed names that deliberately stay in "extra" (report only).
    let extraNames: Set<PyKey>
    /// FNV-1a 64 of the file's bytes, 16 hex digits: changes whenever the file does (part of
    /// `ProfileImporter.fingerprint(aliases:)`).
    public let digest: String

    /// The aliases bundled with the package. The file is part of the build and covered by tests.
    public static let bundled: KeyAliases = {
        guard let url = Bundle.module.url(forResource: "key_aliases", withExtension: "json") else {
            preconditionFailure("key_aliases.json is missing from the PultProfiles bundle")
        }
        do {
            return try KeyAliases(json: Data(contentsOf: url))
        } catch {
            preconditionFailure("key_aliases.json is invalid: \(error)")
        }
    }()

    /// Parses an aliases file; the same checks as `Aliases.__init__` in the Python importer.
    public init(json data: Data) throws {
        let root = try OrderedJSON.parse(data)
        guard case .object(let top) = root else { throw ProfileImportError.invalidAliases("not a JSON object") }
        guard case .object(let keys)? = OrderedJSON.lookup(top, "keys"), !keys.isEmpty else {
            throw ProfileImportError.invalidAliases("'keys' must be a non-empty object")
        }
        var order: [String] = []
        var byKey: [PyKey: [String]] = [:]
        for (key, value) in keys {
            guard case .array(let items) = value else {
                throw ProfileImportError.invalidAliases("'\(key)' must be a list of strings")
            }
            var names: [String] = []
            for item in items {
                guard case .string(let name) = item else {
                    throw ProfileImportError.invalidAliases("'\(key)' must be a list of strings")
                }
                names.append(ProfileNames.normalizeName(name))
            }
            guard Set(names.map(PyKey.init)).count == names.count else {
                throw ProfileImportError.invalidAliases("duplicate alias under '\(key)'")
            }
            order.append(key)
            byKey[PyKey(key)] = names
        }
        var groups: [[(letter: String, key: String)]] = []
        if let value = OrderedJSON.lookup(top, "letterColors") {
            guard case .array(let items) = value else {
                throw ProfileImportError.invalidAliases("'letterColors' must be a list of objects")
            }
            for item in items {
                guard case .object(let pairs) = item else {
                    throw ProfileImportError.invalidAliases("'letterColors' must be a list of objects")
                }
                // {normalize_name(k): v for k, v in group.items()}: first position, last value; then every
                // target must be a key.
                var merged: [(letter: String, target: OrderedJSON)] = []
                for (letter, target) in pairs {
                    let norm = ProfileNames.normalizeName(letter)
                    if let index = merged.firstIndex(where: { Py.equal($0.letter, norm) }) {
                        merged[index].target = target
                    } else {
                        merged.append((norm, target))
                    }
                }
                var group: [(letter: String, key: String)] = []
                for (letter, target) in merged {
                    guard case .string(let key) = target, byKey[PyKey(key)] != nil else {
                        throw ProfileImportError.invalidAliases("letterColors target of '\(letter)' is not a key")
                    }
                    group.append((letter, key))
                }
                groups.append(group)
            }
        }
        var extra = Set<PyKey>()
        if let value = OrderedJSON.lookup(top, "extraNames") {
            guard case .array(let items) = value else {
                throw ProfileImportError.invalidAliases("'extraNames' must be a list of strings")
            }
            for item in items {
                guard case .string(let name) = item else {
                    throw ProfileImportError.invalidAliases("'extraNames' must be a list of strings")
                }
                extra.insert(PyKey(ProfileNames.normalizeName(name)))
            }
        }
        self.keyOrder = order
        self.byKey = byKey
        self.letterGroups = groups
        self.extraNames = extra
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        let hex = String(hash, radix: 16)
        self.digest = String(repeating: "0", count: 16 - hex.count) + hex
    }

    func aliases(for key: String) -> [String] { byKey[PyKey(key)] ?? [] }

    /// `describe_name`: what a normalized button name maps to (import report).
    func describe(_ norm: String) -> String {
        let keys = keyOrder.filter { aliases(for: $0).contains { Py.equal($0, norm) } }
        if !keys.isEmpty {
            return keys.joined(separator: ",")
        }
        let letters = Set(letterGroups.flatMap { group in
            group.filter { Py.equal($0.letter, norm) }.map { PyKey($0.key) }
        }).sorted()
        if !letters.isEmpty {
            return "letter:" + letters.map(\.value).joined(separator: "/")
        }
        return extraNames.contains(PyKey(norm)) ? "extra (reviewed)" : "extra (UNREVIEWED)"
    }
}

/// A JSON value that keeps the order of object members, which `JSONSerialization` does not.
enum OrderedJSON: Equatable {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { Py.equal($0.0, $1.0) && $0.1 == $1.1 }
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)): return Py.equal(x, y)
        case let (.number(x), .number(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    /// `dict[key]` of a parsed object: Python's `json.load` keeps the last value of a repeated member.
    static func lookup(_ pairs: [(String, OrderedJSON)], _ key: String) -> OrderedJSON? {
        pairs.last { Py.equal($0.0, key) }?.1
    }

    /// Parses RFC 8259 JSON. Repeated object members are merged like Python's `dict`: first position, last value.
    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw parser.error("trailing data") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ message: String) -> ProfileImportError {
            .invalidAliases("JSON: \(message) at byte \(index)")
        }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ literal: String) throws {
            let lit = Array(literal.utf8)
            guard bytes.count - index >= lit.count, Array(bytes[index..<index + lit.count]) == lit else {
                throw error("expected \(literal)")
            }
            index += lit.count
        }

        mutating func value(depth: Int) throws -> OrderedJSON {
            guard depth < 64 else { throw error("nested too deep") }
            guard index < bytes.count else { throw error("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var pairs: [(String, OrderedJSON)] = []
                skipSpace()
                if index < bytes.count && bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(pairs)
                }
                while true {
                    skipSpace()
                    let key = try string()
                    skipSpace()
                    try expect(":")
                    skipSpace()
                    let member = try value(depth: depth + 1)
                    if let existing = pairs.firstIndex(where: { Py.equal($0.0, key) }) {
                        pairs[existing].1 = member
                    } else {
                        pairs.append((key, member))
                    }
                    skipSpace()
                    guard index < bytes.count else { throw error("unexpected end") }
                    if bytes[index] == UInt8(ascii: ",") {
                        index += 1
                        continue
                    }
                    try expect("}")
                    return .object(pairs)
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [OrderedJSON] = []
                skipSpace()
                if index < bytes.count && bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(items)
                }
                while true {
                    skipSpace()
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard index < bytes.count else { throw error("unexpected end") }
                    if bytes[index] == UInt8(ascii: ",") {
                        index += 1
                        continue
                    }
                    try expect("]")
                    return .array(items)
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try expect("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null")
                return .null
            default:
                return .number(try number())
            }
        }

        /// An RFC 8259 number: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
        mutating func number() throws -> Double {
            let start = index
            func digits() -> Int {
                let first = index
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                return index - first
            }
            if index < bytes.count && bytes[index] == UInt8(ascii: "-") { index += 1 }
            let integer = index
            guard digits() > 0, bytes[integer] != UInt8(ascii: "0") || index - integer == 1 else {
                throw error("bad number")
            }
            if index < bytes.count && bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw error("bad number") }
            }
            if index < bytes.count && (bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E")) {
                index += 1
                if index < bytes.count && (bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-")) {
                    index += 1
                }
                guard digits() > 0 else { throw error("bad number") }
            }
            guard let text = String(bytes: bytes[start..<index], encoding: .ascii), let value = Double(text) else {
                throw error("bad number")
            }
            return value   // may be infinite, like Python's float("1e400"); aliases never use numbers
        }

        mutating func hex4() throws -> UInt32 {
            guard bytes.count - index >= 4,
                  let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
                  text.unicodeScalars.allSatisfy(Py.isHex), let value = UInt32(text, radix: 16)
            else { throw error("bad \\u escape") }
            index += 4
            return value
        }

        mutating func string() throws -> String {
            try expect("\"")
            var out = String.UnicodeScalarView()
            var run: [UInt8] = []
            func flush() throws {
                guard !run.isEmpty else { return }
                let text = String(decoding: run, as: UTF8.self)
                guard text.utf8.elementsEqual(run) else { throw error("invalid UTF-8") }
                out.append(contentsOf: text.unicodeScalars)
                run.removeAll()
            }
            while true {
                guard index < bytes.count else { throw error("unterminated string") }
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    try flush()
                    return String(out)
                case UInt8(ascii: "\\"):
                    try flush()
                    guard index < bytes.count else { throw error("unterminated string") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append("\"")
                    case UInt8(ascii: "\\"): out.append("\\")
                    case UInt8(ascii: "/"): out.append("/")
                    case UInt8(ascii: "b"): out.append("\u{08}")
                    case UInt8(ascii: "f"): out.append("\u{0C}")
                    case UInt8(ascii: "n"): out.append("\n")
                    case UInt8(ascii: "r"): out.append("\r")
                    case UInt8(ascii: "t"): out.append("\t")
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800..<0xDC00).contains(code) {
                            try expect("\\u")
                            let low = try hex4()
                            guard (0xDC00..<0xE000).contains(low) else { throw error("lone surrogate") }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw error("lone surrogate") }
                        out.append(scalar)
                    default:
                        throw error("bad escape")
                    }
                case 0x00..<0x20:
                    throw error("control character in string")
                default:
                    run.append(byte)
                }
            }
        }
    }
}
