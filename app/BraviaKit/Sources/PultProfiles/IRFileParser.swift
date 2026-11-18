import Foundation

/// One command of a profile, as stored in the generated JSON (profiles/SCHEMA.md).
enum ProfileCommand: Hashable {
    /// {"p": protocol, "a": address, "c": command}
    case parsed(protocol: String, address: Int, command: Int)
    /// {"raw": {"f": carrier Hz, "d": duty %, "i": intro, "r": repeat}}
    case raw(frequency: Int, duty: Int, intro: [Int], repeat: [Int])

    var isRaw: Bool {
        if case .raw = self { return true }
        return false
    }

    /// The protocol name, "raw" for raw recordings (import report).
    var protocolName: String {
        switch self {
        case .parsed(let name, _, _): return name
        case .raw: return "raw"
        }
    }
}

/// A button of a .ir file: the cleaned name and its command.
typealias Button = (name: String, cmd: ProfileCommand)

/// Flipper .ir text -> buttons (import_flipper_irdb.py, ".ir parsing").
enum IRFileParser {
    /// Flipper Zero protocol table: name -> (address bits, command bits), as validated by the Flipper firmware.
    static let protocols: [(name: String, addressBits: Int, commandBits: Int)] = [
        ("NEC", 8, 8),
        ("NECext", 16, 16),
        ("NEC42", 13, 8),
        ("NEC42ext", 26, 16),
        ("Samsung32", 8, 8),
        ("RC5", 5, 6),
        ("RC5X", 5, 7),
        ("RC6", 8, 8),
        ("SIRC", 5, 7),
        ("SIRC15", 8, 7),
        ("SIRC20", 13, 7),
        ("Kaseikyo", 26, 10),
        ("RCA", 4, 8),
        ("Pioneer", 8, 8),
    ]

    static let notIRFile = "file: not an IR signals file"

    private struct Block {
        var name: String
        var data: [String] = []
        var fields: [PyKey: String] = [:]

        func field(_ key: String) -> String? { fields[PyKey(key)] }
    }

    /// `parse_ir_text`: (buttons, errors); errors counts skip reasons.
    static func parseIRText(_ text: String) -> (buttons: [Button], errors: [String: Int]) {
        var errors: [String: Int] = [:]
        var buttons: [Button] = []
        let lines = Py.splitLines(text)
        let header = lines.prefix(4).map(Py.strip).filter { !$0.isEmpty && !Py.starts($0, with: "#") }
        guard let first = header.first, Py.equal(first, "Filetype: IR signals file") else {
            errors[notIRFile, default: 0] += 1
            return (buttons, errors)
        }

        var blocks: [Block] = []
        for rawLine in lines {
            let line = Py.strip(rawLine)
            guard !line.isEmpty, !Py.starts(line, with: "#"), let (rawKey, rawValue) = Py.partition(line, ":") else {
                continue
            }
            let key = Py.strip(rawKey), value = Py.strip(rawValue)
            if Py.equal(key, "name") {
                blocks.append(Block(name: value))
            } else if blocks.isEmpty {
                continue   // file header fields
            } else if Py.equal(key, "data") {
                blocks[blocks.count - 1].data.append(value)
            } else if blocks[blocks.count - 1].fields[PyKey(key)] == nil {
                blocks[blocks.count - 1].fields[PyKey(key)] = value
            }
        }

        for block in blocks {
            let name = ProfileNames.cleanText(block.name)
            var kind = block.field("type")
            if kind == nil && (block.field("protocol") != nil || !block.data.isEmpty) {
                kind = block.field("protocol") != nil ? "parsed" : "raw"
                errors["recovered: missing type inferred from the fields", default: 0] += 1
            }
            let outcome: Result<ProfileCommand, SkipReason>
            if let kind, Py.equal(kind, "parsed") {
                outcome = parseParsedBlock(block)
            } else if let kind, Py.equal(kind, "raw") {
                outcome = parseRawBlock(block)
            } else if kind == nil {
                outcome = .failure("block: missing type")
            } else {
                outcome = .failure("block: unknown type")
            }
            let cmd: ProfileCommand
            switch outcome {
            case .success(let value):
                cmd = value
            case .failure(let reason):
                errors[reason.text, default: 0] += 1
                continue
            }
            if ProfileNames.normalizeName(name).isEmpty {
                errors["block: button without a name", default: 0] += 1
                continue
            }
            if buttons.count >= ImportLimits.maxButtonsPerFile {
                errors["block: more than 256 buttons in one file", default: 0] += 1
                continue
            }
            buttons.append((name, cmd))
        }
        return (buttons, errors)
    }

    private static func parseParsedBlock(_ block: Block) -> Result<ProfileCommand, SkipReason> {
        guard let name = block.field("protocol"), let addressText = block.field("address"),
              let commandText = block.field("command")
        else { return .failure("parsed: missing field") }
        guard let proto = protocols.first(where: { Py.equal($0.name, name) }) else {
            return .failure("parsed: unknown protocol")
        }
        guard let address = parseHexU32(addressText), let command = parseHexU32(commandText) else {
            return .failure("parsed: malformed address/command")
        }
        if address >> proto.addressBits != 0 || command >> proto.commandBits != 0 {
            return .failure("parsed: address/command wider than the protocol")
        }
        return .success(.parsed(protocol: proto.name, address: address, command: command))
    }

    private static func parseRawBlock(_ block: Block) -> Result<ProfileCommand, SkipReason> {
        guard let frequencyText = block.field("frequency"), let dutyText = block.field("duty_cycle"),
              !block.data.isEmpty
        else { return .failure("raw: missing field") }
        let frequency = parseInt(frequencyText)
        let dutyCycle = parseFloat(dutyText)
        let tokens = Py.split(block.data.joined(separator: " "))
        if tokens.count > ImportLimits.maxRawDurations {
            return .failure("raw: recording longer than 4096 durations")
        }
        guard let frequency, let dutyCycle, dutyCycle >= 0 else { return .failure("raw: malformed number") }
        var data: [Int] = []
        data.reserveCapacity(tokens.count)
        for token in tokens {
            guard let value = parseInt(token) else { return .failure("raw: malformed number") }
            data.append(value)
        }
        return RawNormalizer.normalizeRaw(frequency: frequency, dutyCycle: dutyCycle, data: data)
    }

    /// `parse_hex_u32`: four whitespace-separated hex bytes, little-endian.
    static func parseHexU32(_ text: String) -> Int? {
        let parts = Py.split(text)
        guard parts.count == 4 else { return nil }
        var value = 0
        for (i, part) in parts.enumerated() {
            let digits = Py.scalars(part)
            guard digits.count == 2, digits.allSatisfy(Py.isHex), let byte = Int(part, radix: 16) else { return nil }
            value |= byte << (8 * i)
        }
        return value
    }

    /// `parse_number(text, int)`: INT_RE = -?[0-9]{1,9}.
    static func parseInt(_ text: String) -> Int? {
        var digits = Py.scalars(text)
        let negative = digits.first == "-"
        if negative {
            digits.removeFirst()
        }
        guard (1...9).contains(digits.count), digits.allSatisfy(Py.isASCIIDigit) else { return nil }
        let value = digits.reduce(0) { $0 * 10 + Int($1.value - 0x30) }
        return negative ? -value : value
    }

    /// `parse_number(text, float)`: FLOAT_RE = [0-9]{1,6}(\.[0-9]{1,9})?, then `float(text)`.
    static func parseFloat(_ text: String) -> Double? {
        let parts = Py.split(text, separator: ".")
        guard (1...2).contains(parts.count), (1...6).contains(Py.count(parts[0])),
              parts[0].unicodeScalars.allSatisfy(Py.isASCIIDigit)
        else { return nil }
        if parts.count == 2 {
            guard (1...9).contains(Py.count(parts[1])), parts[1].unicodeScalars.allSatisfy(Py.isASCIIDigit) else {
                return nil
            }
        }
        // Both Python's float() and Swift's Double(String) round the decimal correctly.
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }
}
