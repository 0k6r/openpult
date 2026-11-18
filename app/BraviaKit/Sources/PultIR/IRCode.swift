import Foundation

/// Protocols with a parsed (address/command) form. Raw values are the `protocol:` names of the Flipper Zero
/// `.ir` format, and address/command follow Flipper's conventions, so parsed codes from Flipper-IRDB play as-is.
public enum IRProtocolID: String, Codable, CaseIterable, Sendable {
    case nec = "NEC"
    case necext = "NECext"
    case nec42 = "NEC42"
    case nec42ext = "NEC42ext"
    case samsung32 = "Samsung32"
    case sirc = "SIRC"
    case sirc15 = "SIRC15"
    case sirc20 = "SIRC20"
    case rc5 = "RC5"
    case rc5x = "RC5X"
    case rc6 = "RC6"
    case kaseikyo = "Kaseikyo"
    case rca = "RCA"
    case pioneer = "Pioneer"

    /// Address width in the Flipper `.ir` format; encoders ignore higher bits.
    public var addressBits: Int {
        switch self {
        case .rca: 4
        case .sirc, .rc5, .rc5x: 5
        case .nec, .samsung32, .sirc15, .rc6, .pioneer: 8
        case .nec42, .sirc20: 13
        case .necext: 16
        case .nec42ext, .kaseikyo: 26
        }
    }

    /// Command width in the Flipper `.ir` format; encoders ignore higher bits. RC5X accepts 7 bits like Flipper, but
    /// only the low 6 are sent (bit 6 is implied by the protocol) and decoding yields them.
    public var commandBits: Int {
        switch self {
        case .rc5: 6
        case .sirc, .sirc15, .sirc20, .rc5x: 7
        case .nec, .nec42, .samsung32, .rc6, .rca, .pioneer: 8
        case .kaseikyo: 10
        case .necext, .nec42ext: 16
        }
    }
}

/// A parsed IR code. The RC5/RC6 toggle bit is not part of it: see `IRToggleState`.
public struct IRCode: Codable, Equatable, Hashable, Sendable {
    public var proto: IRProtocolID
    public var address: UInt32
    public var command: UInt32

    public init(proto: IRProtocolID, address: UInt32, command: UInt32) {
        self.proto = proto
        self.address = address
        self.command = command
    }
}

/// What a remote button sends: a parsed code, or a raw signal when the protocol is unknown.
///
/// JSON: `{"code": {"proto": "NEC", "address": 4, "command": 8}}` or `{"raw": {<IRSignal>}}`.
public enum IRCommand: Equatable, Hashable, Sendable {
    case code(IRCode)
    case raw(IRSignal)
}

extension IRCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case code, raw
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let code = try container.decodeIfPresent(IRCode.self, forKey: .code) {
            self = .code(code)
        } else {
            self = .raw(try container.decode(IRSignal.self, forKey: .raw))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .code(let code): try container.encode(code, forKey: .code)
        case .raw(let signal): try container.encode(signal, forKey: .raw)
        }
    }
}
