import XCTest
@testable import PultIR

final class IRCodecTests: XCTestCase {
    private func signal(_ proto: IRProtocolID, _ address: UInt32, _ command: UInt32, toggle: Bool = false) -> IRSignal {
        IRCodecs.signal(for: .code(IRCode(proto: proto, address: address, command: command)), toggle: toggle)
    }

    // MARK: - Vectors from sources

    /// LG Power, NEC address 0x04 command 0x08 = 0x20DF10EF (IRremote / LIRC notation); see also nec-lg-power.
    func testNECLGPower() throws {
        let lg = signal(.nec, 0x04, 0x08)
        XCTAssertEqual(transmissionValue(pulseBits(lg.intro, count: 32) { $1 > 1000 }), 0x20DF_10EF)
        XCTAssertEqual(Array(lg.intro.prefix(2)), [9000, 4500])
        XCTAssertEqual(lg.intro.reduce(0, +), 108_000)
        XCTAssertEqual(lg.repeat, [9000, 2250, 562, 96188])
        XCTAssertEqual(lg.carrierHz, 38_000)
        XCTAssertEqual(lg.minRepeats, 1)
        XCTAssertEqual(lg, try loadIRVectors().signal("nec-lg-power").signal)
    }

    /// Samsung TV Power, Samsung32 address 0x07 command 0x02 = 0xE0E040BF.
    func testSamsungPower() {
        let power = signal(.samsung32, 0x07, 0x02)
        XCTAssertTrue(power.intro.isEmpty)
        XCTAssertEqual(Array(power.repeat.prefix(2)), [4500, 4500])
        XCTAssertEqual(transmissionValue(pulseBits(power.repeat, count: 32) { $1 > 1000 }), 0xE0E0_40BF)
        XCTAssertEqual(power.repeat.count, 2 + 64 + 2)
        XCTAssertEqual(power.repeat.reduce(0, +), 108_000)
        XCTAssertEqual(power.minRepeats, 2)
    }

    /// Philips standby, RC5 address 0 command 12: 14 bits 0x300C with toggle 0, 0x380C with toggle 1.
    func testRC5PhilipsStandby() {
        for (toggle, expected) in [(false, 0x300C), (true, 0x380C)] as [(Bool, UInt64)] {
            let frame = signal(.rc5, 0, 12, toggle: toggle).repeat
            var levels = [false] + halfBits(frame, unit: 889)   // the start bit's first half is silence
            if levels.count % 2 == 1 { levels.append(false) }   // so is the last half when it is a space
            XCTAssertEqual(levels.count, 28)
            let bits = stride(from: 0, to: 28, by: 2).map { !levels[$0] && levels[$0 + 1] }   // one = space, mark
            XCTAssertEqual(transmissionValue(bits), expected)
            XCTAssertEqual(frame.reduce(0, +), 114_000)
        }
        let standby = signal(.rc5, 0, 12)
        XCTAssertEqual(standby.repeat, [889, 889, 1778] + Array(repeating: 889, count: 14)
                       + [1778, 889, 889, 1778, 889, 889, 90886])   // computed from the bit layout above
        XCTAssertEqual(standby.carrierHz, 36_000)
        XCTAssertEqual(standby.minRepeats, 2)
    }

    /// Philips Power, RC6 mode 0 address 0 command 0x0C. The durations are computed from the RC6 layout.
    func testRC6PhilipsPower() {
        for toggle in [false, true] {
            let frame = signal(.rc6, 0x00, 0x0C, toggle: toggle).repeat
            XCTAssertEqual(Array(frame.prefix(2)), [2666, 889])
            var levels = halfBits(Array(frame.dropFirst(2)), unit: 444)
            if levels.count % 2 == 1 { levels.append(false) }
            let widths = [1, 1, 1, 1, 2] + Array(repeating: 1, count: 16)
            XCTAssertEqual(levels.count, 2 * widths.reduce(0, +))
            var position = 0
            let bits = widths.map { width -> Bool in
                defer { position += 2 * width }
                return levels[position]   // one = mark, space
            }
            XCTAssertEqual(bits, [true, false, false, false, toggle] + Array(repeating: false, count: 8)
                           + [false, false, false, false, true, true, false, false])
            XCTAssertEqual(frame.reduce(0, +), 107_000)
        }
        XCTAssertEqual(signal(.rc6, 0x00, 0x0C).repeat,
                       [2666, 889, 444, 888, 444, 444, 444, 444, 444, 888, 888]
                       + Array(repeating: 444, count: 22) + [444, 888, 444, 444, 888, 444, 444, 444, 83909])
    }

    /// Panasonic TV Power: Flipper-IRDB `Kaseikyo address 80 02 20 00 command D0 03 00 00`,
    /// on air `02 20 80 00 3D BD` (vendor 0x2002, LSB first).
    func testKaseikyoPanasonicPower() {
        let power = signal(.kaseikyo, 0x0020_0280, 0x3D0)
        let bits = pulseBits(power.repeat, count: 48) { $1 > 864 }
        let bytes = (0..<6).map { byte in (0..<8).reduce(UInt8(0)) { $0 | (bits[8 * byte + $1] ? 1 << $1 : 0) } }
        XCTAssertEqual(bytes, [0x02, 0x20, 0x80, 0x00, 0x3D, 0xBD])
        XCTAssertEqual(Array(power.repeat.prefix(2)), [3456, 1728])
        XCTAssertEqual(power.repeat.reduce(0, +), 130_000)
        XCTAssertEqual(power.carrierHz, 37_000)
        let decoded = KaseikyoCodec.decode(power.repeat)
        XCTAssertEqual(decoded?.code, IRCode(proto: .kaseikyo, address: 0x0020_0280, command: 0x3D0))
    }

    /// Every SIRC code of the shared vectors (IRCC → bits/device/command → transmission value).
    func testSIRCVectors() throws {
        for entry in try loadIRVectors().sirc {
            let proto: IRProtocolID = [12: .sirc, 15: .sirc15, 20: .sirc20][entry.bits]!
            let sony = signal(proto, entry.device, entry.command)
            XCTAssertEqual(sony.carrierHz, 40_000)
            XCTAssertEqual(sony.minRepeats, 3)
            XCTAssertEqual(sony.repeat.reduce(0, +), 45_000, entry.key)
            let bits = pulseBits(sony.repeat, count: entry.bits) { mark, _ in mark > 900 }
            XCTAssertEqual("0x" + String(transmissionValue(bits), radix: 16, uppercase: true), entry.value, entry.key)
            let decoded = SIRCCodec.decode(sony.repeat)
            XCTAssertEqual(decoded?.code, IRCode(proto: proto, address: entry.device, command: entry.command))
        }
    }

    /// RCA Power is `D=15 F=84` in IrpProtocols (MSB first): on air `1111 01010100 0000 10101011`. Flipper reads the
    /// same bits LSB first, so its code is address 0x0F command 0x2A. Computed, not taken from a capture.
    func testRCAPower() {
        let power = signal(.rca, 0x0F, 0x2A)
        XCTAssertEqual(transmissionValue(pulseBits(power.repeat, count: 24) { $1 > 1500 }), 0xF5_40AB)
        XCTAssertEqual(Array(power.repeat.prefix(2)), [4000, 4000])
        XCTAssertEqual(power.repeat.suffix(2), [500, 8000])
        XCTAssertEqual(power.carrierHz, 56_000)
    }

    /// Pioneer address 0xAA command 0x1C: `addr ~addr cmd ~cmd` LSB first = 0x55AA38C7. Computed.
    func testPioneer() {
        let pioneer = signal(.pioneer, 0xAA, 0x1C)
        XCTAssertEqual(transmissionValue(pulseBits(pioneer.repeat, count: 32) { $1 > 1000 }), 0x55AA_38C7)
        XCTAssertEqual(Array(pioneer.repeat.prefix(2)), [8500, 4225])
        XCTAssertEqual(pioneer.repeat.suffix(2), [500, 26500])
        XCTAssertEqual(pioneer.carrierHz, 40_000)
        XCTAssertEqual(pioneer.minRepeats, 2)
    }

    /// NEC42 address 0x1234 command 0x56: `addr13 ~addr13 cmd8 ~cmd8` LSB first, 42 bits. Computed.
    func testNEC42Layout() {
        let frame = signal(.nec42, 0x1234, 0x56).intro
        let bits = pulseBits(frame, count: 42) { $1 > 1000 }
        func field(_ range: Range<Int>) -> UInt32 {
            range.enumerated().reduce(0) { $0 | (bits[$1.element] ? 1 << UInt32($1.offset) : 0) }
        }
        XCTAssertEqual([field(0..<13), field(13..<26), field(26..<34), field(34..<42)],
                       [0x1234, 0x1234 ^ 0x1FFF, 0x56, 0x56 ^ 0xFF] as [UInt32])
        XCTAssertEqual(frame.count, 2 + 84 + 2)
    }

    // MARK: - Flipper conventions

    func testNECWithoutInversionsIsNECext() {
        func decode(_ proto: IRProtocolID, _ address: UInt32, _ command: UInt32) -> IRCode? {
            NECCodec.decode(signal(proto, address, command).intro)?.code
        }
        XCTAssertEqual(decode(.necext, 0xFB04, 0xF708), IRCode(proto: .nec, address: 0x04, command: 0x08))
        XCTAssertEqual(decode(.necext, 0x7F00, 0xF708), IRCode(proto: .necext, address: 0x7F00, command: 0xF708))
        XCTAssertEqual(decode(.necext, 0xFB04, 0x0008), IRCode(proto: .necext, address: 0xFB04, command: 0x0008))
        XCTAssertEqual(decode(.nec42ext, 0x1234 | (0x1234 ^ 0x1FFF) << 13, 0x56 | 0xA9 << 8),
                       IRCode(proto: .nec42, address: 0x1234, command: 0x56))
        XCTAssertEqual(decode(.nec42ext, 0x1234, 0x56), IRCode(proto: .nec42ext, address: 0x1234, command: 0x56))
    }

    func testRC5XClearsS2AndKeepsSixCommandBits() throws {
        let extended = signal(.rc5x, 5, 0x45)
        XCTAssertEqual(extended, signal(.rc5x, 5, 0x05))   // bit 6 is implied, as in Flipper
        XCTAssertNotEqual(extended, signal(.rc5, 5, 0x05))
        let decoded = try XCTUnwrap(RC5Codec.decode(extended.repeat))
        XCTAssertEqual(decoded.code, IRCode(proto: .rc5x, address: 5, command: 0x05))
        XCTAssertEqual(RC5Codec.decode(signal(.rc5, 5, 0x05).repeat)?.code, IRCode(proto: .rc5, address: 5, command: 5))
    }

    func testFieldsAreMaskedToTheirWidth() {
        XCTAssertEqual(signal(.nec, 0x1_04, 0x1_08), signal(.nec, 0x04, 0x08))
        XCTAssertEqual(signal(.sirc, 0x21, 0x95), signal(.sirc, 0x01, 0x15))
        XCTAssertEqual(signal(.rca, 0x1F, 0x12A), signal(.rca, 0x0F, 0x2A))
    }

    // MARK: - Round trips

    private func randomCode(_ proto: IRProtocolID, using rng: inout SeededGenerator) -> IRCode {
        while true {
            let address = UInt32.random(in: 0..<1 << proto.addressBits, using: &rng)
            let command = UInt32.random(in: 0..<1 << (proto == .rc5x ? 6 : proto.commandBits), using: &rng)
            // Extended NEC codes whose halves happen to be inverses are plain NEC codes.
            if proto == .necext, address >> 8 == address & 0xFF ^ 0xFF, command >> 8 == command & 0xFF ^ 0xFF {
                continue
            }
            if proto == .nec42ext, address >> 13 == address & 0x1FFF ^ 0x1FFF, command >> 8 == command & 0xFF ^ 0xFF {
                continue
            }
            return IRCode(proto: proto, address: address, command: command)
        }
    }

    private func testCodes(using rng: inout SeededGenerator) -> [IRCode] {
        IRProtocolID.allCases.flatMap { proto -> [IRCode] in
            let maxCommand = UInt32(1) << (proto == .rc5x ? 6 : proto.commandBits) - 1
            let edges = [IRCode(proto: proto, address: 0, command: 0),
                         IRCode(proto: proto, address: UInt32(1) << proto.addressBits - 1, command: maxCommand)]
            return edges + (0..<25).map { _ in randomCode(proto, using: &rng) }
        }
    }

    func testEveryProtocolRoundTripsThroughReceiverDistortion() {
        var rng = SeededGenerator(seed: 2026)
        for code in testCodes(using: &rng) {
            let codec = IRCodecs.codec(for: code.proto)
            XCTAssertTrue(codec.protocols.contains(code.proto))
            for toggle in IRCodecs.usesToggle(code.proto) ? [false, true] : [false] {
                let signal = codec.encode(code, toggle: toggle)
                XCTAssertNoThrow(try IRSignalBlob.encode(signal), "\(code)")
                for distortion in receiverDistortions {
                    let frame = distort(signal.firstFrame, jitter: distortion.jitter, markShift: distortion.markShift,
                                        using: &rng)
                    let decoded = codec.decode(frame)
                    XCTAssertEqual(decoded?.code, code, "\(code) \(distortion)")
                    XCTAssertEqual(decoded?.toggle, toggle, "\(code) \(distortion)")
                    XCTAssertEqual(decoded?.consumed, frame.count, "\(code) \(distortion)")
                }
            }
        }
    }

    func testEveryProtocolIsRecognizedInACapture() {
        var rng = SeededGenerator(seed: 18)
        for code in testCodes(using: &rng) {
            let signal = IRCodecs.signal(for: .code(code), toggle: true)
            for distortion in receiverDistortions {
                let durations = distort(capture(signal, frames: 3), jitter: distortion.jitter,
                                        markShift: distortion.markShift, using: &rng)
                XCTAssertEqual(IRDecoder.decode(durations), .code(code), "\(code) \(distortion)")
            }
        }
    }

    // MARK: - Registry, toggle state, coding

    func testRegistry() {
        for proto in IRProtocolID.allCases {
            XCTAssertTrue(IRCodecs.codec(for: proto).protocols.contains(proto), "\(proto)")
        }
        XCTAssertEqual(Set(IRCodecs.all.flatMap { $0.protocols }), Set(IRProtocolID.allCases))
        XCTAssertEqual(IRProtocolID.allCases.filter(IRCodecs.usesToggle), [.rc5, .rc5x, .rc6])
        let raw = IRSignal(carrierHz: 38_000, repeat: [500, 20_000], minRepeats: 2)
        XCTAssertEqual(IRCodecs.signal(for: .raw(raw), toggle: true), raw)
        XCTAssertEqual(IRProtocolID(rawValue: "NECext"), .necext)
        XCTAssertEqual(IRProtocolID.kaseikyo.rawValue, "Kaseikyo")
    }

    func testToggleState() {
        var state = IRToggleState()
        let power = IRCode(proto: .rc5, address: 0, command: 12)
        let first = state.toggle(for: power, newPress: true)
        XCTAssertEqual(state.toggle(for: power, newPress: false), first)   // held: HOLD or a resent PLAY
        XCTAssertEqual(state.toggle(for: power, newPress: false), first)
        let second = state.toggle(for: power, newPress: true)
        XCTAssertNotEqual(second, first)
        // Another key of the same remote continues the sequence, as on a real remote; RC5X shares it.
        let third = state.toggle(for: IRCode(proto: .rc5, address: 0, command: 16), newPress: true)
        XCTAssertNotEqual(third, second)
        XCTAssertNotEqual(state.toggle(for: IRCode(proto: .rc5x, address: 0, command: 3), newPress: true), third)
        // Other remotes are independent.
        XCTAssertEqual(state.toggle(for: IRCode(proto: .rc5, address: 5, command: 12), newPress: true), first)
        XCTAssertEqual(state.toggle(for: IRCode(proto: .rc6, address: 0, command: 12), newPress: true), first)
        // Protocols without a toggle bit.
        XCTAssertFalse(state.toggle(for: IRCode(proto: .nec, address: 4, command: 8), newPress: true))
        XCTAssertFalse(state.toggle(for: IRCode(proto: .nec, address: 4, command: 8), newPress: true))
    }

    func testCommandJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let code = IRCommand.code(IRCode(proto: .nec, address: 4, command: 8))
        XCTAssertEqual(String(decoding: try encoder.encode(code), as: UTF8.self),
                       #"{"code":{"address":4,"command":8,"proto":"NEC"}}"#)
        let raw = IRCommand.raw(IRSignal(carrierHz: 38_000, intro: [9000, 4500], repeat: [560, 40_000], minRepeats: 2))
        XCTAssertEqual(String(decoding: try encoder.encode(raw), as: UTF8.self),
                       #"{"raw":{"carrierHz":38000,"dutyPercent":33,"intro":[9000,4500],"minRepeats":2,"#
                       + #""repeat":[560,40000]}}"#)
        for command in [code, raw] {
            XCTAssertEqual(try JSONDecoder().decode(IRCommand.self, from: try encoder.encode(command)), command)
        }
    }
}
