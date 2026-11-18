import Foundation

/// A modulated IR signal as the bridge plays it (firmware/PROTOCOL.md, "Signal blob").
///
/// Durations are microseconds, alternating mark and space and starting with a mark. Each section has an even
/// number of durations and ends with a space: the gap before the next frame belongs to the section.
///
/// One press plays `intro` once followed by `repeat` × `minRepeats`; a repeat-only signal plays `repeat`
/// × max(1, minRepeats) and an intro-only signal plays `intro` × max(1, minRepeats). While a key is held the
/// bridge keeps playing the repeat unit (`repeat`, or `intro` when `repeat` is empty).
public struct IRSignal: Codable, Equatable, Hashable, Sendable {
    public var carrierHz: Int
    /// 10...50 %; 0 selects the bridge default (33 %).
    public var dutyPercent: Int
    public var intro: [Int]
    public var `repeat`: [Int]
    public var minRepeats: Int

    public init(carrierHz: Int, dutyPercent: Int = 33, intro: [Int] = [], repeat: [Int], minRepeats: Int) {
        self.carrierHz = carrierHz
        self.dutyPercent = dutyPercent
        self.intro = intro
        self.repeat = `repeat`
        self.minRepeats = minRepeats
    }

    /// Length of the unit repeated while a key is held: `repeat`, or `intro` if `repeat` is empty.
    public var repeatUnitMicros: Int {
        (self.repeat.isEmpty ? intro : self.repeat).reduce(0) { $0 + min(max($1, 0), 1 << 32) }   // no overflow
    }

    /// The first frame on air: the intro, or the repeat section of a repeat-only signal.
    var firstFrame: [Int] { intro.isEmpty ? self.repeat : intro }
}

/// Why a signal cannot be played by the bridge (ATT error `0x84`) or a blob cannot be parsed.
public enum IRSignalError: Error, Equatable, Sendable {
    /// No durations at all.
    case emptySignal
    /// A section has an odd number of durations, i.e. does not end with a space.
    case oddSection
    /// More than 16 distinct durations (the blob table holds 16).
    case tooManyDistinctDurations
    /// More than 1024 durations, a section longer than 1 s, or a blob over 576 bytes.
    case tooLong
    /// A duration outside 1...500000 µs.
    case durationOutOfRange
    /// A carrier outside 20000...65535 Hz.
    case carrierOutOfRange
    /// A duty cycle outside 10...50 % (0 means the default).
    case dutyOutOfRange
    /// `minRepeats` outside 0...20.
    case repeatsOutOfRange
    /// A mark longer than 30 ms.
    case markTooLong
    /// `IRSignalBlob.decode` only: the bytes are not a well-formed blob.
    case malformedBlob
}
