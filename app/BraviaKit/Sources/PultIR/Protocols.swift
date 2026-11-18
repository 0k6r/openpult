import Foundation

// Address/command layouts follow the Flipper Zero infrared library (lib/infrared/encoder_decoder in
// flipperzero-firmware) so that parsed codes from Flipper-IRDB play as recorded. Timings: SB-Projects,
// IrpProtocols.xml (IrpTransmogrifier), Arduino-IRremote and Flipper; deviations are noted per codec.

private func mask(_ value: UInt32, _ bits: Int) -> UInt64 {
    UInt64(value) & (1 << UInt64(bits) - 1)
}

private func code(_ proto: IRProtocolID, _ address: UInt64, _ command: UInt64) -> IRCode {
    IRCode(proto: proto, address: UInt32(address), command: UInt32(command))
}

/// NEC family, 38 kHz, LSB first: NEC `addr8 ~addr8 cmd8 ~cmd8`, NECext `addr16 cmd16`,
/// NEC42 `addr13 ~addr13 cmd8 ~cmd8`, NEC42ext `addr26 cmd16`. A 32-bit frame without both inversions is NECext,
/// a 42-bit one NEC42ext, as in Flipper. Frame and repeat code (9000/2250/562) every 108 ms.
enum NECCodec: IRCodec {
    static let protocols: [IRProtocolID] = [.nec, .necext, .nec42, .nec42ext]
    static let format = PulseFormat(header: [9000, 4500], zero: Pulse(562, 562), one: Pulse(562, 1687),
                                    stopMark: 562, spacing: .period(108_000))
    static let repeatCode = [9000, 2250, 562]

    static func encode(_ code: IRCode, toggle: Bool) -> IRSignal {
        let a = mask(code.address, code.proto.addressBits)
        let c = mask(code.command, code.proto.commandBits)
        let frame: [Int]
        switch code.proto {
        case .necext: frame = format.frame(a | c << 16, bits: 32)
        case .nec42: frame = format.frame(a | (a ^ 0x1FFF) << 13 | c << 26 | (c ^ 0xFF) << 34, bits: 42)
        case .nec42ext: frame = format.frame(a | c << 26, bits: 42)
        default: frame = format.frame(a | (a ^ 0xFF) << 8 | c << 16 | (c ^ 0xFF) << 24, bits: 32)
        }
        return IRSignal(carrierHz: 38_000, intro: frame, repeat: repeatCode + [108_000 - repeatCode.reduce(0, +)],
                        minRepeats: 1)
    }

    static func decode(_ d: [Int]) -> (code: IRCode, toggle: Bool, consumed: Int)? {
        guard let frame = format.read(d) else { return nil }
        let v = frame.value
        let result: IRCode
        switch frame.bits {
        case 32:
            let (a, c) = (v & 0xFF, v >> 16 & 0xFF)
            result = v >> 8 & 0xFF == a ^ 0xFF && v >> 24 == c ^ 0xFF
                ? code(.nec, a, c) : code(.necext, v & 0xFFFF, v >> 16)
        case 42:
            let (a, c) = (v & 0x1FFF, v >> 26 & 0xFF)
            result = v >> 13 & 0x1FFF == a ^ 0x1FFF && v >> 34 == c ^ 0xFF
                ? code(.nec42, a, c) : code(.nec42ext, v & 0x3FF_FFFF, v >> 26)
        default:
            return nil
        }
        var consumed = frame.consumed
        while consumed + repeatCode.count <= d.count,
              zip(repeatCode, d[consumed...]).allSatisfy({ isClose($1, to: $0) }) {
            let end = consumed + repeatCode.count
            guard end == d.count || d[end] >= format.gapThreshold else { break }
            consumed = min(end + 1, d.count)
        }
        return (result, false, consumed)
    }
}

/// Samsung32, 38 kHz: 4500/4500, `addr8 addr8 cmd8 ~cmd8` LSB first, the whole frame repeated every 108 ms
/// (IrpProtocols; Flipper's 46/97 ms repeat code is not sent).
enum Samsung32Codec: IRCodec {
    static let protocols: [IRProtocolID] = [.samsung32]
    static let format = PulseFormat(header: [4500, 4500], zero: Pulse(560, 560), one: Pulse(560, 1690),
                                    stopMark: 560, spacing: .period(108_000))

    static func encode(_ code: IRCode, toggle: Bool) -> IRSignal {
        let (a, c) = (mask(code.address, 8), mask(code.command, 8))
        return IRSignal(carrierHz: 38_000, repeat: format.frame(a | a << 8 | c << 16 | (c ^ 0xFF) << 24, bits: 32),
                        minRepeats: 2)
    }

    static func decode(_ d: [Int]) -> (code: IRCode, toggle: Bool, consumed: Int)? {
        guard let frame = format.read(d), frame.bits == 32 else { return nil }
        let v = frame.value
        guard v & 0xFF == v >> 8 & 0xFF, v >> 24 == v >> 16 & 0xFF ^ 0xFF else { return nil }
        return (code(.samsung32, v & 0xFF, v >> 16 & 0xFF), false, frame.consumed)
    }
}

/// Sony SIRC 12/15/20, 40 kHz, T = 600: 2400/600 header, a one is a 1200 mark, `cmd7 dev5|8|13` LSB first,
/// frames every 45 ms, at least 3. SIRC20's address is `device5 | extended8 << 5`.
enum SIRCCodec: IRCodec {
    static let protocols: [IRProtocolID] = [.sirc, .sirc15, .sirc20]
    static let format = PulseFormat(header: [2400, 600], zero: Pulse(600, 600), one: Pulse(1200, 600),
                                    stopMark: nil, spacing: .period(45_000))

    static func encode(_ code: IRCode, toggle: Bool) -> IRSignal {
        let addressBits = code.proto.addressBits
        let value = mask(code.command, 7) | mask(code.address, addressBits) << 7
        return IRSignal(carrierHz: 40_000, repeat: format.frame(value, bits: 7 + addressBits), minRepeats: 3)
    }

    static func decode(_ d: [Int]) -> (code: IRCode, toggle: Bool, consumed: Int)? {
        guard let frame = format.read(d),
              let proto = protocols.first(where: { 7 + $0.addressBits == frame.bits }) else { return nil }
        return (code(proto, frame.value >> 7, frame.value & 0x7F), false, frame.consumed)
    }
}

/// Philips RC5 / RC5X, 36 kHz, bi-phase with 889 µs halves, MSB first: `1 S2 T addr5 cmd6`; S2 = 1 for RC5 and 0
/// for RC5X (the inverted 7th command bit). Frames every 114 ms, at least 2.
enum RC5Codec: IRCodec {
    static let protocols: [IRProtocolID] = [.rc5, .rc5x]
    static let format = ManchesterFormat(unit: 889, header: [], widths: Array(repeating: 1, count: 14),
                                         oneStartsWithMark: false, startsWithSpace: true, period: 114_000)

    static func encode(_ code: IRCode, toggle: Bool) -> IRSignal {
        let bits = [true, code.proto != .rc5x, toggle] + msbFirst(code.address, 5) + msbFirst(code.command, 6)
        return IRSignal(carrierHz: 36_000, repeat: format.frame(bits), minRepeats: 2)
    }

    static func decode(_ d: [Int]) -> (code: IRCode, toggle: Bool, consumed: Int)? {
        guard let frame = format.read(d), frame.bits[0] else { return nil }
        let bits = frame.bits
        let result = IRCode(proto: bits[1] ? .rc5 : .rc5x, address: msbValue(bits[3..<8]),
                            command: msbValue(bits[8..<14]))
        return (result, bits[2], frame.consumed)
    }
}

/// Philips RC6 mode 0, 36 kHz, T = 444: leader 2666/889, then bi-phase MSB first `1 000 T addr8 cmd8`, the toggle
/// bit twice as wide. Frames every 107 ms, at least 2.
enum RC6Codec: IRCodec {
    static let protocols: [IRProtocolID] = [.rc6]
    static let format = ManchesterFormat(unit: 444, header: [2666, 889],
                                         widths: [1, 1, 1, 1, 2] + Array(repeating: 1, count: 16),
                                         oneStartsWithMark: true, startsWithSpace: false, period: 107_000)

    static func encode(_ code: IRCode, toggle: Bool) -> IRSignal {
        let bits = [true, false, false, false, toggle] + msbFirst(code.address, 8) + msbFirst(code.command, 8)
        return IRSignal(carrierHz: 36_000, repeat: format.frame(bits), minRepeats: 2)
    }

    static func decode(_ d: [Int]) -> (code: IRCode, toggle: Bool, consumed: Int)? {
        guard let frame = format.read(d), frame.bits[0], !frame.bits[1...3].contains(true) else { return nil }
        let bits = frame.bits
        return (IRCode(proto: .rc6, address: msbValue(bits[5..<13]), command: msbValue(bits[13..<21])),
                bits[4], frame.consumed)
    }
}

/// Kaseikyo (Panasonic, Denon, JVC 48-bit...), T = 432: 3456/1728, 48 bits LSB first in bytes
/// `vendor16 | parity4 genre1_4 | genre2_4 cmd10 id2 | xor8`. Flipper's address is
/// `id << 24 | vendor << 8 | genre1 << 4 | genre2`, the command 10 bits. 37 kHz (Flipper sends 38), every 130 ms.
enum KaseikyoCodec: IRCodec {
    static let protocols: [IRProtocolID] = [.kaseikyo]
    static let format = PulseFormat(header: [3456, 1728], zero: Pulse(432, 432), one: Pulse(432, 1296),
                                    stopMark: 432, spacing: .period(130_000))

    static func encode(_ code: IRCode, toggle: Bool) -> IRSignal {
        let (a, c) = (code.address, code.command & 0x3FF)
        var bytes = [UInt8](repeating: 0, count: 6)
        bytes[0] = UInt8(a >> 8 & 0xFF)
        bytes[1] = UInt8(a >> 16 & 0xFF)
        bytes[2] = vendorParity(bytes[0], bytes[1]) | UInt8(a >> 4 & 0xF) << 4
        bytes[3] = UInt8(a & 0xF) | UInt8(c & 0xF) << 4
        bytes[4] = UInt8(a >> 24 & 0x3) << 6 | UInt8(c >> 4)
        bytes[5] = bytes[2] ^ bytes[3] ^ bytes[4]
        let value = bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) }
        return IRSignal(carrierHz: 37_000, repeat: format.frame(value, bits: 48), minRepeats: 1)
    }

    static func decode(_ d: [Int]) -> (code: IRCode, toggle: Bool, consumed: Int)? {
        guard let frame = format.read(d), frame.bits == 48 else { return nil }
        let b = (0..<6).map { UInt8(frame.value >> UInt64(8 * $0) & 0xFF) }
        guard b[2] & 0xF == vendorParity(b[0], b[1]), b[5] == b[2] ^ b[3] ^ b[4] else { return nil }
        let address = UInt32(b[4] >> 6) << 24 | UInt32(b[1]) << 16 | UInt32(b[0]) << 8
            | UInt32(b[2] >> 4) << 4 | UInt32(b[3] & 0xF)
        let command = UInt32(b[3] >> 4) | UInt32(b[4] & 0x3F) << 4
        return (IRCode(proto: .kaseikyo, address: address, command: command), false, frame.consumed)
    }

    private static func vendorParity(_ low: UInt8, _ high: UInt8) -> UInt8 {
        let x = low ^ high
        return (x ^ x >> 4) & 0xF
    }
}

/// RCA: 4000/4000, 500 marks, spaces 1000/2000, `addr4 cmd8 ~addr4 ~cmd8` LSB first as in Flipper (the IRP form
/// is MSB first, so Flipper's values are bit-reversed against it), 8 ms after each frame. 56 kHz like RCA remotes
/// (Flipper sends 38).
enum RCACodec: IRCodec {
    static let protocols: [IRProtocolID] = [.rca]
    static let format = PulseFormat(header: [4000, 4000], zero: Pulse(500, 1000), one: Pulse(500, 2000),
                                    stopMark: 500, spacing: .gap(8_000))

    static func encode(_ code: IRCode, toggle: Bool) -> IRSignal {
        let (a, c) = (mask(code.address, 4), mask(code.command, 8))
        return IRSignal(carrierHz: 56_000, repeat: format.frame(a | c << 4 | (a ^ 0xF) << 12 | (c ^ 0xFF) << 16,
                                                                bits: 24),
                        minRepeats: 1)
    }

    static func decode(_ d: [Int]) -> (code: IRCode, toggle: Bool, consumed: Int)? {
        guard let frame = format.read(d), frame.bits == 24 else { return nil }
        let v = frame.value
        let (a, c) = (v & 0xF, v >> 4 & 0xFF)
        guard v >> 12 & 0xF == a ^ 0xF, v >> 16 == c ^ 0xFF else { return nil }
        return (code(.rca, a, c), false, frame.consumed)
    }
}

/// Pioneer, 40 kHz, Flipper timings: 8500/4225, 500 marks, spaces 500/1500, `addr8 ~addr8 cmd8 ~cmd8` LSB first,
/// 26.5 ms after each frame, at least 2 frames.
enum PioneerCodec: IRCodec {
    static let protocols: [IRProtocolID] = [.pioneer]
    static let format = PulseFormat(header: [8500, 4225], zero: Pulse(500, 500), one: Pulse(500, 1500),
                                    stopMark: 500, spacing: .gap(26_500))

    static func encode(_ code: IRCode, toggle: Bool) -> IRSignal {
        let (a, c) = (mask(code.address, 8), mask(code.command, 8))
        return IRSignal(carrierHz: 40_000, repeat: format.frame(a | (a ^ 0xFF) << 8 | c << 16 | (c ^ 0xFF) << 24,
                                                                bits: 32),
                        minRepeats: 2)
    }

    static func decode(_ d: [Int]) -> (code: IRCode, toggle: Bool, consumed: Int)? {
        guard let frame = format.read(d), frame.bits == 32 else { return nil }
        let v = frame.value
        let (a, c) = (v & 0xFF, v >> 16 & 0xFF)
        guard v >> 8 & 0xFF == a ^ 0xFF, v >> 24 == c ^ 0xFF else { return nil }
        return (code(.pioneer, a, c), false, frame.consumed)
    }
}
