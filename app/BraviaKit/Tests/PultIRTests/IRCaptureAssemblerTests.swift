import XCTest
@testable import PultIR

final class IRCaptureAssemblerTests: XCTestCase {
    /// Capture notifications as the bridge sends them, split on varint boundaries.
    private func notifications(id: UInt8, durations: [Int], flags: UInt8 = 0, size: Int = 20) -> [Data] {
        var chunks: [[UInt8]] = [[]]
        for duration in durations {
            var varint: [UInt8] = []
            var rest = duration
            repeat {
                varint.append(UInt8(rest & 0x7F) | (rest > 0x7F ? 0x80 : 0))
                rest >>= 7
            } while rest > 0
            let room = size - (chunks.count == 1 ? 5 : 2)
            if chunks[chunks.count - 1].count + varint.count > room { chunks.append([]) }
            chunks[chunks.count - 1] += varint
        }
        return chunks.enumerated().map { index, chunk in
            let frag = UInt8(index) | (index == chunks.count - 1 ? 0x80 : 0)
            let header = index == 0
                ? [id, frag, flags, UInt8(durations.count & 0xFF), UInt8(durations.count >> 8)] : [id, frag]
            return Data(header + chunk)
        }
    }

    private let sample = [9000, 4500, 562, 1687, 562, 39970, 127, 128, 16384, 1]

    private func feed(_ assembler: inout IRCaptureAssembler, _ notifications: [Data]) -> [IRCaptureResult?] {
        notifications.map { assembler.append($0) }
    }

    func testSingleAndMultipleFragments() {
        var assembler = IRCaptureAssembler()
        XCTAssertEqual(feed(&assembler, notifications(id: 1, durations: sample, size: 244)),
                       [.durations(sample, truncated: false)])
        let long = (0..<512).map { 300 + $0 * 37 }
        let parts = notifications(id: 2, durations: long, flags: 0x01)
        XCTAssertGreaterThan(parts.count, 50)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 20 })
        let results = feed(&assembler, parts)
        XCTAssertEqual(results.last, .durations(long, truncated: true))
        XCTAssertTrue(results.dropLast().allSatisfy { $0 == nil })
    }

    func testTimeout() {
        var assembler = IRCaptureAssembler()
        XCTAssertEqual(assembler.append(Data([0x03, 0x80, 0x02, 0x00, 0x00])), .timeout)
        XCTAssertEqual(feed(&assembler, notifications(id: 4, durations: sample)).last, .durations(sample, truncated: false))
    }

    func testGarbageAndMissedStarts() {
        var assembler = IRCaptureAssembler()
        XCTAssertNil(assembler.append(Data()))
        XCTAssertNil(assembler.append(Data([0x07])))
        XCTAssertNil(assembler.append(Data([0x07, 0x02, 0x10, 0x20])))              // continuation without a start
        XCTAssertEqual(assembler.append(Data([0x07, 0x83, 0x10, 0x20])), .corrupted)  // ... up to its last fragment
        XCTAssertEqual(assembler.append(Data([0x07, 0x80, 0x00])), .corrupted)        // fragment 0 without a count
        XCTAssertEqual(feed(&assembler, notifications(id: 7, durations: sample)).last,
                       .durations(sample, truncated: false))

        // The first fragment of a capture is lost: reported once, at the end.
        let parts = notifications(id: 12, durations: sample + sample, size: 12)
        XCTAssertGreaterThan(parts.count, 3)
        let results = feed(&assembler, Array(parts.dropFirst()))
        XCTAssertEqual(results.last, .corrupted)
        XCTAssertTrue(results.dropLast().allSatisfy { $0 == nil })
    }

    func testLostFragmentsAndBadLengths() {
        var assembler = IRCaptureAssembler()
        var parts = notifications(id: 5, durations: sample + sample, size: 12)
        XCTAssertGreaterThan(parts.count, 3)
        parts.remove(at: 1)
        let results = feed(&assembler, parts)
        XCTAssertEqual(results[1], .corrupted)
        XCTAssertTrue(results.dropFirst(2).allSatisfy { $0 == nil })   // reported once, the rest is dropped

        // A fragment of another capture in the middle.
        let first = notifications(id: 6, durations: sample, size: 12)
        XCTAssertNil(assembler.append(first[0]))
        XCTAssertEqual(assembler.append(notifications(id: 9, durations: sample, size: 12)[1]), .corrupted)

        // Count mismatch and a varint cut at the end.
        var mismatch = notifications(id: 8, durations: sample, size: 244)[0]
        mismatch[3] = 11
        XCTAssertEqual(assembler.append(mismatch), .corrupted)
        XCTAssertEqual(assembler.append(Data([0x08, 0x80, 0x00, 0x01, 0x00, 0x90])), .corrupted)

        // A new capture after a lost LAST starts over.
        XCTAssertNil(assembler.append(notifications(id: 10, durations: sample, size: 12)[0]))
        XCTAssertEqual(feed(&assembler, notifications(id: 11, durations: sample, size: 12)).last,
                       .durations(sample, truncated: false))
    }
}
