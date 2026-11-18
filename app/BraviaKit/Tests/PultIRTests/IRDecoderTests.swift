import XCTest
@testable import PultIR

final class IRDecoderTests: XCTestCase {
    private var rng = SeededGenerator(seed: 42)

    /// Like a real capture: jitter plus marks stretched by the receiver.
    private func received(_ durations: [Int]) -> [Int] {
        distort(durations, jitter: 0.15, markShift: 80, using: &rng)
    }

    /// A made-up protocol no codec knows: 1500/3500 header, 300 µs marks, 300/900 µs spaces, 20 bits, stop mark,
    /// frames every 60 ms.
    private func unknownFrame(_ value: UInt32) -> [Int] {
        var frame = [1500, 3500]
        for bit in 0..<20 {
            frame += [300, value >> bit & 1 == 1 ? 900 : 300]
        }
        frame.append(300)
        return frame + [60_000 - frame.reduce(0, +)]
    }

    private let unknownRepeat = [1500, 1500, 300, 90_000]

    private struct NotRaw: Error {
        let command: IRCommand
    }

    private func raw(_ command: IRCommand) throws -> IRSignal {
        guard case .raw(let signal) = command else { throw NotRaw(command: command) }
        return signal
    }

    /// Each value within the jitter of its nominal duration shifted like the capture.
    private func assertClose(_ actual: [Int], _ nominal: [Int], markShift: Int, line: UInt = #line) {
        XCTAssertEqual(actual.count, nominal.count, line: line)
        for (index, (value, expected)) in zip(actual, nominal).enumerated() {
            let skewed = expected + (index % 2 == 0 ? markShift : -markShift)
            XCTAssertLessThanOrEqual(abs(value - skewed), expected * 15 / 100 + 20, "#\(index)", line: line)
        }
    }

    // MARK: - Recognized codes

    func testNECWithRepeatCodes() {
        let lg = IRCode(proto: .nec, address: 0x04, command: 0x08)
        let durations = received(capture(IRCodecs.signal(for: .code(lg), toggle: false), frames: 5))
        XCTAssertEqual(durations.count, 68 + 4 * 4 - 1)
        let decoded = NECCodec.decode(durations)
        XCTAssertEqual(decoded?.code, lg)
        XCTAssertEqual(decoded?.consumed, durations.count)   // the repeat codes belong to the press
        XCTAssertEqual(IRDecoder.decode(durations), .code(lg))
    }

    func testRC5TwoPresses() {
        let standby = IRCode(proto: .rc5, address: 0, command: 12)
        let (first, second) = (RC5Codec.encode(standby, toggle: false), RC5Codec.encode(standby, toggle: true))
        let durations = received(Array((first.repeat + first.repeat + second.repeat + second.repeat).dropLast()))
        XCTAssertEqual(IRDecoder.decode(durations), .code(standby))
        var toggles: [Bool] = []
        var position = 0
        while position < durations.count, let frame = RC5Codec.decode(Array(durations[position...])) {
            toggles.append(frame.toggle)
            position += frame.consumed
        }
        XCTAssertEqual(toggles, [false, false, true, true])
        XCTAssertEqual(position, durations.count)
    }

    func testPioneerIsNotTakenForNEC() {
        let code = IRCode(proto: .pioneer, address: 0x04, command: 0x08)
        XCTAssertNotNil(NECCodec.decode(PioneerCodec.encode(code, toggle: false).repeat), "NEC-like on purpose")
        for _ in 0..<20 {
            XCTAssertEqual(IRDecoder.decode(received(capture(PioneerCodec.encode(code, toggle: false), frames: 2))),
                           .code(code))
            let lg = IRCode(proto: .nec, address: 0x04, command: 0x08)
            XCTAssertEqual(IRDecoder.decode(received(capture(NECCodec.encode(lg, toggle: false), frames: 1))),
                           .code(lg))
        }
    }

    /// Frames are found by the decoders, not by a fixed silence threshold: RCA frames are 8 ms apart, SIRC20 with
    /// all ones only 6.6 ms, while NEC has a 4.5 ms space inside its header.
    func testShortFrameGapsNeedNoPreSplitting() {
        let rca = IRCode(proto: .rca, address: 0x0F, command: 0x2A)
        let sirc20 = IRCode(proto: .sirc20, address: 0x1FFF, command: 0x7F)
        XCTAssertEqual(SIRCCodec.encode(sirc20, toggle: false).repeat.last, 6600)
        for code in [rca, sirc20] {
            let signal = IRCodecs.signal(for: .code(code), toggle: false)
            XCTAssertEqual(IRDecoder.decode(received(capture(signal, frames: 4))), .code(code))
        }
    }

    func testTruncatedLastFrameIsIgnored() {
        let back = IRCode(proto: .sirc15, address: 151, command: 35)
        let frame = SIRCCodec.encode(back, toggle: false).repeat
        let durations = received(frame + frame + frame + Array(frame.prefix(25)))   // the bridge stopped mid-frame
        XCTAssertEqual(SIRCCodec.decode(Array(durations.suffix(25)))?.code.proto, .sirc)
        XCTAssertEqual(IRDecoder.decode(durations), .code(back))
    }

    func testDisagreeingFramesFallBackToRaw() throws {
        let a = NECCodec.encode(IRCode(proto: .nec, address: 4, command: 8), toggle: false).intro
        let b = NECCodec.encode(IRCode(proto: .nec, address: 4, command: 9), toggle: false).intro
        let signal = try raw(IRDecoder.decode(received(Array((a + b).dropLast()))))
        XCTAssertEqual(signal.intro.count, a.count)
        XCTAssertEqual(signal.repeat.count, b.count)
    }

    // MARK: - Raw signals

    func testUnknownSignalBecomesIntroAndRepeat() throws {
        let intro = unknownFrame(0xA_5C3F)
        let durations = received(Array((intro + unknownRepeat + unknownRepeat + unknownRepeat).dropLast()))
        let signal = try raw(IRDecoder.decode(durations))
        XCTAssertEqual(signal.carrierHz, 38_000)
        XCTAssertEqual(signal.minRepeats, 2)
        assertClose(Array(signal.intro.dropLast()), Array(intro.dropLast()), markShift: 80)
        assertClose(Array(signal.repeat.dropLast()), Array(unknownRepeat.dropLast()), markShift: 80)
        XCTAssertEqual(Double(signal.intro.last!), Double(intro.last!), accuracy: Double(intro.last!) * 0.2)
        XCTAssertEqual(Double(signal.repeat.last!), 90_000, accuracy: 15_000)
        XCTAssertLessThanOrEqual(Set(signal.intro + signal.repeat).count, 16)
        XCTAssertNoThrow(try IRSignalBlob.encode(signal))
    }

    func testRepeatedUnknownFrameBecomesRepeatOnly() throws {
        let frame = unknownFrame(0x1_2345)
        let signal = try raw(IRDecoder.decode(received(Array((frame + frame + frame).dropLast()))))
        XCTAssertTrue(signal.intro.isEmpty)
        assertClose(Array(signal.repeat.dropLast()), Array(frame.dropLast()), markShift: 80)
        XCTAssertNoThrow(try IRSignalBlob.encode(signal))

        // A single frame that ends with the capture gets a gap.
        let single = try raw(IRDecoder.decode(received(Array(frame.dropLast()))))
        XCTAssertTrue(single.intro.isEmpty)
        XCTAssertEqual(single.repeat.count, frame.count)
        XCTAssertEqual(single.repeat.last, IRDecoder.rawDefaultGap)
    }

    func testRawSignalsKeepAtMostSixteenDurations() throws {
        let marks = [300, 450, 650, 900, 1300, 1900]
        let spaces = (0..<18).map { Int(250 * pow(1.19, Double($0))) }
        let frame = spaces.enumerated().flatMap { [marks[$0.offset % marks.count], $0.element] } + [400, 30_000]
        XCTAssertGreaterThan(Set(frame).count, 16)
        // Neighbouring durations only 19 % apart: little jitter, or no clustering could keep the frames equal.
        let durations = distort(Array((frame + frame).dropLast()), jitter: 0.03, markShift: 80, using: &rng)
        let signal = try raw(IRDecoder.decode(durations))
        XCTAssertTrue(signal.intro.isEmpty)
        XCTAssertEqual(signal.repeat.count, frame.count)
        XCTAssertLessThanOrEqual(Set(signal.repeat).count, 16)
        XCTAssertNoThrow(try IRSignalBlob.encode(signal))
    }

    func testSameCommand() throws {
        let frame = unknownFrame(0xA_5C3F)
        let first = IRDecoder.decode(received(Array((frame + unknownRepeat).dropLast())))
        let again = IRDecoder.decode(received(Array((frame + unknownRepeat + unknownRepeat).dropLast())))
        let once = IRDecoder.decode(received(Array(frame.dropLast())))
        let other = IRDecoder.decode(received(Array((unknownFrame(0xA_5C3E) + unknownRepeat).dropLast())))
        XCTAssertTrue(IRDecoder.sameCommand(first, again))
        XCTAssertTrue(IRDecoder.sameCommand(first, once))   // only the first frame identifies the button
        XCTAssertFalse(IRDecoder.sameCommand(first, other))

        let power = IRCommand.code(IRCode(proto: .rc5, address: 0, command: 12))
        XCTAssertTrue(IRDecoder.sameCommand(power, IRDecoder.decode(received(capture(
            RC5Codec.encode(IRCode(proto: .rc5, address: 0, command: 12), toggle: true), frames: 2)))))
        XCTAssertFalse(IRDecoder.sameCommand(power, .code(IRCode(proto: .rc5, address: 0, command: 13))))
        XCTAssertFalse(IRDecoder.sameCommand(power, first))
    }

    func testFrameBreaksFollowTheLongestPauses() {
        let nec = NECCodec.encode(IRCode(proto: .nec, address: 4, command: 8), toggle: false)
        let durations = capture(nec, frames: 3)
        XCTAssertEqual(IRDecoder.frameBreaks(durations), [67, 71])            // not the 4.5 ms header space
        XCTAssertEqual(IRDecoder.frameBreaks(Array(nec.intro.dropLast())), [])  // a single frame
    }

    /// The bridge stops recording on the final silence, so a capture ends on a mark (odd count).
    func testOddCaptureEndsOnAMark() throws {
        let lg = IRCode(proto: .nec, address: 0x04, command: 0x08)
        let nec = received(capture(NECCodec.encode(lg, toggle: false), frames: 2))
        XCTAssertEqual(nec.count % 2, 1)
        XCTAssertEqual(NECCodec.decode(nec)?.consumed, nec.count)
        XCTAssertEqual(IRDecoder.decode(nec), .code(lg))

        // Raw: the last frame gets the gap seen between the frames.
        let frame = unknownFrame(0x3_C3C3)
        let durations = Array((frame + frame + frame).dropLast())
        XCTAssertEqual(durations.count % 2, 1)
        let signal = try raw(IRDecoder.decode(durations))
        XCTAssertTrue(signal.intro.isEmpty)
        XCTAssertEqual(signal.repeat, frame)
        XCTAssertNoThrow(try IRSignalBlob.encode(signal))
        // A lone frame gets the default gap.
        XCTAssertEqual(try raw(IRDecoder.decode(Array(frame.dropLast())))
            .repeat, Array(frame.dropLast()) + [IRDecoder.rawDefaultGap])
    }

    // MARK: - Review findings

    func testNoiseBeforeAFrame() {
        let lg = IRCode(proto: .nec, address: 0x04, command: 0x08)
        let durations = [150, 3000] + received(capture(NECCodec.encode(lg, toggle: false), frames: 3))
        XCTAssertEqual(IRDecoder.decode(durations), .code(lg))
    }

    /// A code that is only the tail of unknown frames must not win over them (when the unknown part is at least
    /// half as long as the code's frame; shorter stretches count as interference).
    func testCodeLookalikeInsideUnknownFramesStaysRaw() throws {
        let tail = Array(RC5Codec.encode(IRCode(proto: .rc5, address: 3, command: 9), toggle: false).repeat.dropLast())
        let frame = [6000, 1500] + Array(repeating: [300, 900], count: 6).joined() + tail + [50_000]
        _ = try raw(IRDecoder.decode(received(Array((frame + frame).dropLast()))))
        _ = try raw(IRDecoder.decode(received(Array(frame.dropLast()))))
    }

    /// Sharp/Denon style: two different frames alternate while the key is held.
    func testAlternatingFramesRepeatAsAPair() throws {
        let (a, b) = (unknownFrame(0x1_2345), unknownFrame(0xE_DCBA))
        let signal = try raw(IRDecoder.decode(received(Array((a + b + a + b + a).dropLast()))))
        XCTAssertTrue(signal.intro.isEmpty)
        XCTAssertEqual(signal.repeat.count, a.count + b.count)
        XCTAssertEqual(IRDecoder.sections([[1, 2], [3, 4], [1, 2], [3]]).repeat, [1, 2, 3, 4])   // cut last frame
        XCTAssertEqual(IRDecoder.sections([[1, 2], [3, 4], [5, 6]]).intro, [1, 2])              // no period
        XCTAssertEqual(IRDecoder.sections([[1, 2], [1, 7], [3, 4]]).repeat, [1, 2])             // spec: 2 == 1
    }

    /// Frames 8 ms apart with a 4 ms header space: only a 2× jump between pauses.
    func testCloseFramesAreSplit() throws {
        var frame = [4000, 4000]
        for bit in 0..<24 { frame += [500, 0x12_3456 >> bit & 1 == 1 ? 2000 : 1000] }
        frame += [500, 8000]
        let signal = try raw(IRDecoder.decode(received(Array((frame + frame + frame + frame).dropLast()))))
        XCTAssertTrue(signal.intro.isEmpty)
        XCTAssertEqual(signal.repeat.count, frame.count)
        XCTAssertTrue(IRDecoder.sameCommand(.raw(signal), IRDecoder.decode(received(Array(frame.dropLast())))))
    }

    func testRawSignalsArePlayable() throws {
        // A held key of an unknown remote, cut by the bridge at 512 durations.
        let frame = unknownFrame(0x5_A5A5)
        let held = Array(Array(repeating: frame, count: 20).joined().prefix(512))
        for durations in [held, Array(held.dropLast())] {
            let signal = try raw(IRDecoder.decode(received(durations)))
            XCTAssertTrue(signal.intro.isEmpty)
            XCTAssertEqual(signal.repeat.count, frame.count)
            XCTAssertNoThrow(try IRSignalBlob.encode(signal))
        }
        // No structure at all, about 1 s long, with a 40 ms mark.
        var noise = (0..<511).map { _ in Int.random(in: 200...3800, using: &rng) }
        noise[0] = 40_000
        let signal = try raw(IRDecoder.decode(noise))
        XCTAssertEqual(signal.firstFrame.first, IRSignalBlob.maxMark)
        XCTAssertNoThrow(try IRSignalBlob.encode(signal))
        for _ in 0..<300 {
            let count = Int.random(in: 1...512, using: &rng)
            let captured = (0..<count).map { _ in Int.random(in: 0...140_000, using: &rng) }
            guard case .raw(let fuzzed) = IRDecoder.decode(captured) else { continue }
            XCTAssertNoThrow(try IRSignalBlob.encode(fuzzed), "\(captured)")
        }
    }

    func testClustersDoNotChain() {
        let marks = [2600, 3640, 4100, 4300, 4500, 4900]
        let clustered = IRDecoder.clustered(marks.flatMap { [$0, 1000] }, limit: 16)
        let values = stride(from: 0, to: clustered.count, by: 2).map { clustered[$0] }
        XCTAssertEqual(values[0], 2600)
        XCTAssertEqual(Set(values.dropFirst()).count, 1)
        let header = IRDecoder.clustered([4545, 4500] + (0..<9).flatMap { [7707 + $0 * 100, 2250] }, limit: 16)
        XCTAssertEqual(header[0], 4545)
        XCTAssertEqual(Set(stride(from: 2, to: header.count, by: 2).map { header[$0] }).count, 1)
    }

    func testCodeAndRawOfTheSameButton() {
        let lg = IRCode(proto: .nec, address: 0x04, command: 0x08)
        let captured = received(capture(NECCodec.encode(lg, toggle: false), frames: 2))
        XCTAssertTrue(IRDecoder.sameCommand(.code(lg), .raw(IRDecoder.normalize(captured))))
        XCTAssertFalse(IRDecoder.sameCommand(.code(IRCode(proto: .nec, address: 0x04, command: 0x09)),
                                             .raw(IRDecoder.normalize(captured))))
        let standby = IRCode(proto: .rc5, address: 0, command: 12)
        let toggled = received(capture(RC5Codec.encode(standby, toggle: true), frames: 1))
        XCTAssertTrue(IRDecoder.sameCommand(.raw(IRDecoder.normalize(toggled)), .code(standby)))
    }

    func testAbsurdDurationsDoNotTrap() {
        let inputs: [[Int]] = [[], [0], [1000, .max], [.max], [.min, 5], [9000, 4500, 562, .max - 100, 562],
                               [2666, 889, 500, .max], [.max, .max, .max, .max], [-5, -5, -5, -5]]
        for input in inputs {
            _ = IRDecoder.decode(input)
            for codec in IRCodecs.all { _ = codec.decode(input) }
        }
        XCTAssertEqual(IRDecoder.decode([]), .raw(IRSignal(carrierHz: 38_000, repeat: [], minRepeats: 2)))
    }
}
