import Foundation

/// A Sony SIRC infrared code, as sent by the IR bridge.
///
/// IRCC codes are base64 of 13 bytes: `u32 BE type | u32 BE device | u32 BE command | u8`,
/// where type 1/2/3 means 12/15/20-bit SIRC. See firmware/PROTOCOL.md.
public struct SIRCCode: Equatable, Hashable, Sendable {
    public enum Bits: UInt8, Sendable {
        case b12 = 12, b15 = 15, b20 = 20

        var deviceBits: Int { Int(rawValue) - 7 }
    }

    public let bits: Bits
    /// For 20-bit codes: `device5 | extended8 << 5`.
    public let device: UInt16
    public let command: UInt8

    public init?(bits: Bits, device: UInt16, command: UInt8) {
        guard command < 128, Int(device) < (1 << bits.deviceBits) else { return nil }
        self.bits = bits
        self.device = device
        self.command = command
    }

    public init?(ircc: String) {
        guard let data = Data(base64Encoded: ircc), data.count == 13 else { return nil }
        let bytes = [UInt8](data)
        func word(at offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        let bits: Bits
        switch word(at: 0) {
        case 1: bits = .b12
        case 2: bits = .b15
        case 3: bits = .b20
        default: return nil
        }
        let device = word(at: 4)
        let command = word(at: 8)
        guard device <= UInt32(UInt16.max), command <= UInt32(UInt8.max) else { return nil }
        self.init(bits: bits, device: UInt16(device), command: UInt8(command))
    }

    /// Bits in transmission order (command LSB first, then device LSB first),
    /// written MSB-first — the notation used by IRremote / Tasmota (Power = 0xA90).
    public var transmissionValue: UInt32 {
        var value: UInt32 = 0
        for index in 0..<7 {
            value = value << 1 | UInt32(command >> index & 1)
        }
        for index in 0..<bits.deviceBits {
            value = value << 1 | UInt32(device >> index & 1)
        }
        return value
    }
}
