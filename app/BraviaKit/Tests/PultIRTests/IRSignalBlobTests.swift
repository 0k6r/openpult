import XCTest
@testable import PultIR

final class IRSignalBlobTests: XCTestCase {
    func testBlobsAndPlayWritesMatchSharedVectors() throws {
        let vectors = try loadIRVectors()
        XCTAssertGreaterThanOrEqual(vectors.signals.count, 3)
        for vector in vectors.signals {
            let blob = try IRSignalBlob.encode(vector.signal)
            XCTAssertEqual(blob.hex, vector.blobHex, vector.name)
            XCTAssertEqual(IRSignalBlob.playWrites(blob, sigID: 1, maxWrite: 244).map(\.hex), vector.playHex,
                           vector.name)
            XCTAssertEqual(IRSignalBlob.playWrites(blob, sigID: 1, maxWrite: 20).map(\.hex), vector.playHexMtu23,
                           vector.name)
            XCTAssertEqual(try IRSignalBlob.decode(blob), vector.signal, vector.name)
        }
    }

    func testCodecsProduceTheVectorSignals() throws {
        let vectors = try loadIRVectors()
        XCTAssertEqual(SIRCCodec.encode(IRCode(proto: .sirc, address: 1, command: 21), toggle: false),
                       try vectors.signal("sony-power-sirc12").signal)
        XCTAssertEqual(NECCodec.encode(IRCode(proto: .nec, address: 0x04, command: 0x08), toggle: false),
                       try vectors.signal("nec-lg-power").signal)
    }

    func testTableIsInOrderOfFirstAppearanceIntroFirst() throws {
        let signal = IRSignal(carrierHz: 38_000, intro: [300, 700, 300, 900], repeat: [100, 700, 300, 5000],
                              minRepeats: 1)
        let blob = [UInt8](try IRSignalBlob.encode(signal))
        XCTAssertEqual(blob[4], 5)
        // 300, 700, 900, 100, 5000 as varints, then the nibbles.
        XCTAssertEqual(Data(blob[9...]).hex, "ac02bc05840764" + "8827" + "0102" + "3104")
    }

    func testPlayWritesFragmentation() throws {
        let blob = Data((0..<576).map { UInt8($0 & 0xFF) })
        let writes = IRSignalBlob.playWrites(blob, sigID: 0x2A, maxWrite: 512)   // capped at 244
        XCTAssertEqual(writes.map(\.count), [244, 244, 100])
        XCTAssertEqual(writes.map { $0[3] }, [0x00, 0x01, 0x82])
        XCTAssertTrue(writes.allSatisfy { $0.prefix(3) == Data([0x10, 0x00, 0x2A]) })
        XCTAssertEqual(Data(writes.flatMap { $0.dropFirst(4) }), blob)
        XCTAssertEqual(IRSignalBlob.playWrites(blob, sigID: 1, maxWrite: 20).count, 36)
        XCTAssertEqual(IRSignalBlob.playWrites(Data(), sigID: 7, maxWrite: 20), [Data([0x10, 0x00, 0x07, 0x80])])
    }

    func testHold() throws {
        XCTAssertEqual(IRSignalBlob.hold(sigID: 9, count: 5), Data([0x11, 0x09, 0x05]))
        for example in try loadIRVectors().hold.examples {
            let signal = IRSignal(carrierHz: 38_000, repeat: [500, example.repeatUnitUs - 500], minRepeats: 1)
            XCTAssertEqual(Int(IRSignalBlob.holdCount(for: signal)), example.count)
        }
        func count(unit: Int, intro: Bool = false) -> UInt8 {
            let section = [500, unit - 500]
            return IRSignalBlob.holdCount(for: intro ? IRSignal(carrierHz: 38_000, intro: section, repeat: [],
                                                                minRepeats: 1)
                                                     : IRSignal(carrierHz: 38_000, intro: [9000, 1000],
                                                                repeat: section, minRepeats: 1))
        }
        XCTAssertEqual(count(unit: 90_000), 3)       // exactly 2 units + 1
        XCTAssertEqual(count(unit: 89_999), 4)
        XCTAssertEqual(count(unit: 9_000), 20)       // clamped
        XCTAssertEqual(count(unit: 500_000), 2)      // clamped
        XCTAssertEqual(count(unit: 45_000, intro: true), 5)   // intro-only: the intro is the repeat unit
        XCTAssertEqual(SIRCCodec.encode(IRCode(proto: .sirc, address: 1, command: 21), toggle: false).repeatUnitMicros,
                       45_000)
        // A signal from bad JSON must not trap.
        XCTAssertEqual(IRSignalBlob.holdCount(for: IRSignal(carrierHz: 38_000, repeat: [.max, 1], minRepeats: 1)), 2)
    }

    func testLimits() throws {
        func signal(_ intro: [Int] = [], _ repeatSection: [Int] = [500, 500], carrier: Int = 38_000, duty: Int = 33,
                    repeats: Int = 1) -> IRSignal {
            IRSignal(carrierHz: carrier, dutyPercent: duty, intro: intro, repeat: repeatSection, minRepeats: repeats)
        }
        let cases: [(IRSignal, IRSignalError)] = [
            (signal([], []), .emptySignal),
            (signal([], [500]), .oddSection),
            (signal([500, 500, 500], [500, 500]), .oddSection),
            (signal(carrier: 19_999), .carrierOutOfRange),
            (signal(carrier: 65_536), .carrierOutOfRange),
            (signal(duty: 9), .dutyOutOfRange),
            (signal(duty: 51), .dutyOutOfRange),
            (signal(repeats: 21), .repeatsOutOfRange),
            (signal(repeats: -1), .repeatsOutOfRange),
            (signal([], [500, 0]), .durationOutOfRange),
            (signal([], [500, 500_001]), .durationOutOfRange),
            (signal([], [30_001, 500]), .markTooLong),
            (signal([30_001, 500]), .markTooLong),
            (signal([], [30_000, 500_000, 30_000, 440_001]), .tooLong),
            (signal(Array(repeating: 500, count: 1000), Array(repeating: 500, count: 26)), .tooLong),
            (signal([], (1...17).flatMap { [500, 1000 + $0] }), .tooManyDistinctDurations),
        ]
        for (signal, error) in cases {
            XCTAssertThrowsError(try IRSignalBlob.encode(signal), "\(signal)") {
                XCTAssertEqual($0 as? IRSignalError, error, "\(signal)")
            }
        }
        // Exactly at the limits.
        let edges = [
            signal(duty: 0), signal(duty: 10, repeats: 0), signal(carrier: 20_000, duty: 50, repeats: 20),
            signal(carrier: 65_535), signal([], [30_000, 500_000, 30_000, 440_000]),
            signal(Array(repeating: 500, count: 1000), Array(repeating: 500, count: 24)),
            signal([], (1...15).flatMap { [500, 1000 + $0] }),   // 16 distinct
        ]
        for signal in edges {
            let blob = try IRSignalBlob.encode(signal)
            XCTAssertLessThanOrEqual(blob.count, IRSignalBlob.maxBlobBytes)
            XCTAssertEqual(try IRSignalBlob.decode(blob), signal)
        }
    }

    func testDecodeRejectsMalformedBlobs() throws {
        let valid = [UInt8](try IRSignalBlob.encode(try loadIRVectors().signal("nec-lg-power").signal))
        func rejects(_ bytes: [UInt8], _ error: IRSignalError = .malformedBlob, line: UInt = #line) {
            XCTAssertThrowsError(try IRSignalBlob.decode(Data(bytes)), line: line) {
                XCTAssertEqual($0 as? IRSignalError, error, line: line)
            }
        }
        rejects([])
        rejects(valid + [UInt8](repeating: 0, count: IRSignalBlob.maxBlobBytes + 1 - valid.count), .tooLong)
        rejects(Array(valid.prefix(8)))                      // header cut
        rejects(Array(valid.dropLast()))                     // symbols cut
        rejects(valid + [0])                                 // trailing byte
        var bytes = valid
        bytes[4] = 0                                         // empty table
        rejects(bytes)
        bytes[4] = 17                                        // table too big
        rejects(bytes)
        rejects([0x40, 0x9C, 0x21, 0x03, 0x01, 0x00, 0x00, 0x02, 0x00, 0x80])   // varint cut
        rejects([0x40, 0x9C, 0x21, 0x03, 0x01, 0x00, 0x00, 0x02, 0x00, 0x05, 0x01])  // symbol 1 of a 1-entry table
        rejects([0x40, 0x9C, 0x21, 0x03, 0x02, 0x00, 0x00, 0x02, 0x00, 0x05, 0x00, 0x01], .durationOutOfRange)
        rejects([0x10, 0x27, 0x21, 0x03, 0x01, 0x00, 0x00, 0x02, 0x00, 0x05, 0x00], .carrierOutOfRange)
        rejects([0x40, 0x9C, 0x21, 0x03, 0x01, 0x00, 0x00, 0x01, 0x00, 0x05, 0x00], .oddSection)
        rejects([0x40, 0x9C, 0x21, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x05], .emptySignal)
    }

    func testRandomSignalsRoundTrip() throws {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<200 {
            let pool = (0..<Int.random(in: 1...16, using: &rng)).map { _ in Int.random(in: 1...12_000, using: &rng) }
            func section() -> [Int] {
                (0..<Int.random(in: 0...40, using: &rng) * 2).map { _ in pool.randomElement(using: &rng)! }
            }
            var signal = IRSignal(carrierHz: Int.random(in: 20_000...65_535, using: &rng),
                                  dutyPercent: Int.random(in: 10...50, using: &rng), intro: section(),
                                  repeat: section(), minRepeats: Int.random(in: 0...20, using: &rng))
            if signal.intro.isEmpty && signal.repeat.isEmpty { signal.repeat = [pool[0], pool[0]] }
            XCTAssertEqual(try IRSignalBlob.decode(try IRSignalBlob.encode(signal)), signal)
        }
    }
}
