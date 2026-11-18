import Foundation

/// The JSON text of the generated files, byte for byte as Python's `json.dumps` writes it
/// (import_flipper_irdb.py, "Output").
enum ProfileWriter {
    /// A JSON string literal: `json.dumps(s, ensure_ascii=...)`.
    static func quote(_ s: String, ensureASCII: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        out.append("\"")
        func hex4(_ v: UInt32) {
            let digits = String(v, radix: 16)
            out.append(contentsOf: ("\\u" + String(repeating: "0", count: 4 - digits.count) + digits).unicodeScalars)
        }
        for c in s.unicodeScalars {
            switch c {
            case "\"": out.append(contentsOf: "\\\"".unicodeScalars)
            case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
            case "\u{08}": out.append(contentsOf: "\\b".unicodeScalars)
            case "\u{0C}": out.append(contentsOf: "\\f".unicodeScalars)
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            case "\t": out.append(contentsOf: "\\t".unicodeScalars)
            default:
                if c.value < 0x20 {
                    hex4(c.value)
                } else if ensureASCII && c.value > 0x7E {
                    if c.value >= 0x10000 {
                        let v = c.value - 0x10000
                        hex4(0xD800 | (v >> 10))
                        hex4(0xDC00 | (v & 0x3FF))
                    } else {
                        hex4(c.value)
                    }
                } else {
                    out.append(c)
                }
            }
        }
        out.append("\"")
        return String(out)
    }

    static func intList(_ values: [Int], separator: String = ",") -> String {
        "[" + values.map(String.init).joined(separator: separator) + "]"
    }

    static func stringList(_ values: [String], separator: String = ",") -> String {
        "[" + values.map { quote($0) }.joined(separator: separator) + "]"
    }

    // MARK: Files

    /// `format_profiles`: one brand file.
    static func formatProfiles(_ profiles: [Profile]) -> String {
        var out = ["["]
        for (pi, p) in profiles.enumerated() {
            out.append("  {")
            out.append("    \"id\": \(quote(p.id)),")
            out.append("    \"brand\": \(quote(p.brand)),")
            out.append("    \"name\": \(quote(p.name)),")
            out.append("    \"models\": \(stringList(p.models)),")
            out.append("    \"weight\": \(p.weight),")
            out.append("    \"source\": \(stringList(p.source)),")
            if p.keys.isEmpty {
                out.append("    \"keys\": {},")
            } else {
                out.append("    \"keys\": {")
                for (i, entry) in p.keys.enumerated() {
                    out.append("      \(quote(entry.key)): \(entry.cmd.json)" + (i < p.keys.count - 1 ? "," : ""))
                }
                out.append("    },")
            }
            if p.extra.isEmpty {
                out.append("    \"extra\": []")
            } else {
                out.append("    \"extra\": [")
                for (i, e) in p.extra.enumerated() {
                    out.append("      " + extraJSON(e) + (i < p.extra.count - 1 ? "," : ""))
                }
                out.append("    ]")
            }
            out.append("  }" + (pi < profiles.count - 1 ? "," : ""))
        }
        out.append("]")
        return out.joined(separator: "\n") + "\n"
    }

    static func extraJSON(_ e: Button) -> String {
        "{\"name\":\(quote(e.name)),\"cmd\":\(e.cmd.json)}"
    }

    /// `format_power_scan`.
    static func formatPowerScan(_ entries: [PowerScanCode]) -> String {
        if entries.isEmpty {
            return "[]\n"
        }
        let rows = entries.map { e in
            "  {\"cmd\":\(e.cmd.json),\"brands\":\(stringList(e.brands)),\"weight\":\(e.weight)}"
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n]\n"
    }

    /// `format_index`; the values use `separators=(", ", ": ")`.
    static func formatIndex(schema: Int, source: [(String, String)], brands: [IndexBrand]) -> String {
        let sourceJSON = "{" + source.map { "\(quote($0.0)): \(quote($0.1))" }.joined(separator: ", ") + "}"
        let rows = brands.map { b in
            "    {\"id\": \(quote(b.id)), \"name\": \(quote(b.name)), \"file\": \(quote(b.file)), "
                + "\"profiles\": \(b.profiles)}"
        }
        let lines = [
            "{",
            "  \"schema\": \(schema),",
            "  \"source\": \(sourceJSON),",
            "  \"brands\": [",
            rows.joined(separator: ",\n"),
            "  ]",
            "}",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}

extension ProfileCommand {
    /// `dumps(cmd)`: insertion order, compact separators.
    var json: String {
        switch self {
        case let .parsed(name, address, command):
            return "{\"p\":\(ProfileWriter.quote(name)),\"a\":\(address),\"c\":\(command)}"
        case let .raw(frequency, duty, intro, rep):
            return "{\"raw\":{\"f\":\(frequency),\"d\":\(duty),\"i\":\(ProfileWriter.intList(intro)),"
                + "\"r\":\(ProfileWriter.intList(rep))}}"
        }
    }

    /// `canonical(cmd)`: `json.dumps(cmd, sort_keys=True, separators=(",", ":"))`, pure ASCII.
    var canonical: String {
        switch self {
        case let .parsed(name, address, command):
            return "{\"a\":\(address),\"c\":\(command),\"p\":\(ProfileWriter.quote(name, ensureASCII: true))}"
        case let .raw(frequency, duty, intro, rep):
            return "{\"raw\":{\"d\":\(duty),\"f\":\(frequency),\"i\":\(ProfileWriter.intList(intro)),"
                + "\"r\":\(ProfileWriter.intList(rep))}}"
        }
    }
}
