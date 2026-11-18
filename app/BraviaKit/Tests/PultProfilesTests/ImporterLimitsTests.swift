import Foundation
import XCTest
@testable import PultIR
@testable import PultProfiles

/// The importer only emits raw signals the bridge can play: its limits must be PultIR's.
final class ImporterLimitsTests: XCTestCase {
    func testLimitsEqualSignalBlobLimits() {
        XCTAssertEqual(BlobLimits.blobMax, IRSignalBlob.maxBlobBytes)
        XCTAssertEqual(BlobLimits.tableMax, IRSignalBlob.maxTable)
        XCTAssertEqual(BlobLimits.symbolsMax, IRSignalBlob.maxSymbols)
        XCTAssertEqual(BlobLimits.markMax, IRSignalBlob.maxMark)
        XCTAssertEqual(BlobLimits.sectionMax, IRSignalBlob.maxSection)
        XCTAssertEqual(BlobLimits.durationMax, IRSignalBlob.durations.upperBound)
        // The importer is stricter at the low end: shorter durations are receiver noise.
        XCTAssertGreaterThanOrEqual(RawNormalizer.durationMin, IRSignalBlob.durations.lowerBound)
    }

    private func signal(carrier: Int = 38_000, duty: Int = 33, intro: [Int] = [], repeat: [Int]) -> IRSignal {
        IRSignal(carrierHz: carrier, dutyPercent: duty, intro: intro, repeat: `repeat`, minRepeats: 1)
    }

    func testCarrierAndDutyRangesMatchTheEncoder() {
        for carrier in [BlobLimits.carrier.lowerBound, BlobLimits.carrier.upperBound] {
            XCTAssertNoThrow(try IRSignalBlob.encode(signal(carrier: carrier, repeat: [500, 500])))
        }
        for carrier in [BlobLimits.carrier.lowerBound - 1, BlobLimits.carrier.upperBound + 1] {
            XCTAssertThrowsError(try IRSignalBlob.encode(signal(carrier: carrier, repeat: [500, 500])))
        }
        for duty in [BlobLimits.duty.lowerBound, BlobLimits.duty.upperBound] {
            XCTAssertNoThrow(try IRSignalBlob.encode(signal(duty: duty, repeat: [500, 500])))
        }
        for duty in [BlobLimits.duty.lowerBound - 1, BlobLimits.duty.upperBound + 1] {
            XCTAssertThrowsError(try IRSignalBlob.encode(signal(duty: duty, repeat: [500, 500])))
        }
    }

    /// blob_size is the exact size of the encoded blob, header included.
    func testBlobSizeMatchesEncoder() throws {
        var generator = SplitMix64(seed: 20_261_118)
        for _ in 0..<300 {
            // At most 40 durations of at most 20 ms per section: always under the 1 s section limit.
            let table = (0..<Int.random(in: 1...BlobLimits.tableMax, using: &generator)).map { _ in
                Int.random(in: RawNormalizer.durationMin...20_000, using: &generator)
            }
            func section(_ pairs: Int) -> [Int] { (0..<2 * pairs).map { _ in table.randomElement(using: &generator)! } }
            let intro = section(Int.random(in: 0...20, using: &generator))
            let rep = section(Int.random(in: 1...20, using: &generator))
            let blob = try IRSignalBlob.encode(signal(intro: intro, repeat: rep))
            XCTAssertEqual(RawNormalizer.blobSize(intro: intro, repeat: rep), blob.count)
        }
    }

    /// Everything normalize_raw accepts encodes, and the largest accepted recordings sit at the limits.
    func testAcceptedRecordingsEncode() throws {
        let longest = RawNormalizer.normalizeRaw(frequency: 38_000, dutyCycle: 0.33, data: [300, 600] * 511 + [300])
        guard case .success(.raw(let f, let d, let intro, let rep)) = longest else { return XCTFail("\(longest)") }
        XCTAssertEqual(intro.count + rep.count, BlobLimits.symbolsMax)
        XCTAssertNoThrow(try IRSignalBlob.encode(signal(carrier: f, duty: d, intro: intro, repeat: rep)))
        XCTAssertEqual(try? RawNormalizer.normalizeRaw(frequency: 38_000, dutyCycle: 0.33,
                                                       data: [300, 600] * 512 + [300]).get(), nil)
    }
}

private func * (values: [Int], count: Int) -> [Int] {
    Array((0..<count).map { _ in values }.joined())
}

/// A seeded generator, so a failing case can be reproduced.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
