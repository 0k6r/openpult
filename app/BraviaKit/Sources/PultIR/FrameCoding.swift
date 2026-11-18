import Foundation

// Generic frame coders shared by the protocol codecs: pulse distance / pulse width, and bi-phase (Manchester).
//
// Decoders read one frame from the start of a duration list (mark first) and report how many durations they
// consumed, including the gap after the frame. They tolerate what a demodulating receiver does to a signal:
// random jitter and marks stretched at the expense of the following space.

/// Timing match used by all decoders: ±30 % or ±250 µs, whichever is wider.
func isClose(_ measured: Int, to nominal: Int) -> Bool {
    abs(min(max(measured, 0), maxDuration) - nominal) <= max(nominal * 3 / 10, 250)
}

/// Longest duration the decoders take as is (over an hour); longer or negative values are clamped, so that no
/// input can overflow their arithmetic.
let maxDuration = 1 << 32

func sanitized(_ durations: [Int]) -> [Int] {
    durations.map { min(max($0, 0), maxDuration) }
}

/// Spaces at least this long can end a frame in every supported protocol.
let minFrameGap = 4000

/// How the space after the last mark of a frame is chosen.
enum FrameSpacing: Sendable {
    /// Frames start every `period` µs.
    case period(Int)
    /// A fixed silence after the last mark.
    case gap(Int)
}

struct Pulse: Sendable {
    let mark: Int
    let space: Int

    init(_ mark: Int, _ space: Int) {
        self.mark = mark
        self.space = space
    }
}

/// Header + one (mark, space) pair per bit, LSB first. Pulse-distance codes (bits differ in the space) end with a
/// stop mark; pulse-width codes (bits differ in the mark, SIRC) end with the last bit's mark, its space being the gap.
struct PulseFormat: Sendable {
    let header: [Int]
    let zero: Pulse
    let one: Pulse
    let stopMark: Int?
    let spacing: FrameSpacing

    /// A space at least this long after a mark ends the frame.
    var gapThreshold: Int { max(max(zero.space, one.space) * 5 / 2, minFrameGap) }

    func frame(_ value: UInt64, bits: Int) -> [Int] {
        var out = header
        for index in 0..<bits {
            let pulse = value >> UInt64(index) & 1 == 1 ? one : zero
            out += [pulse.mark, pulse.space]
        }
        if let stopMark {
            out.append(stopMark)
        } else {
            out.removeLast()
        }
        let length = out.reduce(0, +)
        switch spacing {
        case .period(let period): out.append(max(period - length, gapThreshold * 3 / 2))   // long NEC42ext frames
        case .gap(let gap): out.append(gap)
        }
        return out
    }

    /// Reads the bits of one frame (LSB first); the bit count is whatever the frame holds, up to 64.
    func read(_ captured: [Int]) -> (value: UInt64, bits: Int, consumed: Int)? {
        let d = sanitized(captured)
        guard d.count > header.count, zip(header, d).allSatisfy({ isClose($1, to: $0) }) else { return nil }
        var value: UInt64 = 0
        var bits = 0
        var index = header.count
        while index < d.count {
            let mark = d[index]
            let space = index + 1 < d.count ? d[index + 1] : nil
            guard let space, space < gapThreshold else {
                // The frame ends after this mark.
                let consumed = min(index + 2, d.count)
                if let stopMark {
                    return isClose(mark, to: stopMark) ? (value, bits, consumed) : nil
                }
                guard bits < 64, let bit = bit(mark: mark, space: nil) else { return nil }
                return (value | bit << UInt64(bits), bits + 1, consumed)
            }
            guard bits < 64, let bit = bit(mark: mark, space: space) else { return nil }
            value |= bit << UInt64(bits)
            bits += 1
            index += 2
        }
        return nil
    }

    private func bit(mark: Int, space: Int?) -> UInt64? {
        if zero.mark == one.mark {
            // Pulse distance: judge the whole bit period, which mark/space skew does not change.
            guard let space, isClose(mark, to: zero.mark) else { return nil }
            let period = mark + space
            let (zeroPeriod, onePeriod) = (zero.mark + zero.space, one.mark + one.space)
            let isOne = abs(period - onePeriod) < abs(period - zeroPeriod)
            return isClose(period, to: isOne ? onePeriod : zeroPeriod) ? (isOne ? 1 : 0) : nil
        }
        // Pulse width: judge the mark; the space is fixed.
        if let space, !isClose(space, to: zero.space) { return nil }
        let isOne = abs(mark - one.mark) < abs(mark - zero.mark)
        return isClose(mark, to: isOne ? one.mark : zero.mark) ? (isOne ? 1 : 0) : nil
    }
}

/// Bi-phase code: every bit is two equal halves of opposite level, `widths[i]` units each (RC6's toggle bit is
/// twice as wide). Adjacent halves of the same level merge into one mark or space.
struct ManchesterFormat: Sendable {
    let unit: Int
    let header: [Int]
    /// Bit widths in units, in transmission order.
    let widths: [Int]
    /// A one is mark-then-space (RC6), otherwise space-then-mark (RC5).
    let oneStartsWithMark: Bool
    /// The first half-bit is a space hidden in the silence before the frame (RC5's start bit).
    let startsWithSpace: Bool
    let period: Int

    var gapThreshold: Int { max(6 * unit, minFrameGap) }

    func frame(_ bits: [Bool]) -> [Int] {
        precondition(bits.count == widths.count)
        var runs: [(mark: Bool, length: Int)] = []
        func add(_ mark: Bool, _ length: Int) {
            if runs.last?.mark == mark {
                runs[runs.count - 1].length += length
            } else {
                runs.append((mark, length))
            }
        }
        for (index, duration) in header.enumerated() {
            add(index % 2 == 0, duration)
        }
        for (bit, width) in zip(bits, widths) {
            let firstIsMark = bit == oneStartsWithMark
            add(firstIsMark, width * unit)
            add(!firstIsMark, width * unit)
        }
        if runs.first?.mark == false { runs.removeFirst() }
        if runs.last?.mark == false { runs.removeLast() }
        let out = runs.map(\.length)
        return out + [max(period - out.reduce(0, +), gapThreshold)]
    }

    /// Reads one frame. Each mark or space must end on a half-bit boundary the code allows from where it starts
    /// (every mid-bit has a transition), so a duration only ever chooses between two lengths.
    func read(_ captured: [Int]) -> (bits: [Bool], consumed: Int)? {
        let d = sanitized(captured)
        guard d.count > header.count else { return nil }
        if let frame = read(d, skew: 0) { return frame }
        // Undo the mark stretch estimated from the frame only when needed: with jitter alone the estimate is noise.
        let skew = markSkew(d, from: header.count)
        return skew == 0 ? nil : read(d, skew: skew)
    }

    private func read(_ d: [Int], skew: Int) -> (bits: [Bool], consumed: Int)? {
        for (index, nominal) in header.enumerated() where !isClose(d[index] + (index % 2 == 0 ? -skew : skew),
                                                                     to: nominal) {
            return nil
        }
        let last = widths.count - 1
        var firstHalves = [Bool](repeating: true, count: widths.count)
        var bit = 0
        var atMid = startsWithSpace
        if startsWithSpace { firstHalves[0] = false }
        var mark = true
        var index = header.count
        while true {
            if atMid && bit == last && !mark {
                // The space of the final half-bit runs into the gap.
                guard index == d.count || d[index] >= gapThreshold else { return nil }
                index = min(index + 1, d.count)
                break
            }
            guard index < d.count else { return nil }
            let measured = d[index] + (mark ? -skew : skew)
            // From a bit boundary the run ends at the mid-bit; from a mid-bit, at the next boundary or next mid-bit.
            var options: [(units: Int, toMid: Bool)] = [(widths[bit], !atMid)]
            if atMid && bit < last { options.append((widths[bit] + widths[bit + 1], true)) }
            let choice = options.min { ratio(measured, $0.units) < ratio(measured, $1.units) }!
            guard isClose(measured, to: choice.units * unit) else { return nil }
            index += 1
            if atMid {
                if bit == last {
                    // A mark ended the frame: a gap or the end of the capture follows.
                    guard index == d.count || d[index] >= gapThreshold else { return nil }
                    index = min(index + 1, d.count)
                    break
                }
                bit += 1
                firstHalves[bit] = choice.toMid ? mark : !mark
            }
            atMid = choice.toMid
            mark.toggle()
        }
        return (firstHalves.map { $0 == oneStartsWithMark }, index)
    }

    private func ratio(_ measured: Int, _ units: Int) -> Double {
        let (a, b) = (Double(max(measured, 1)), Double(units * unit))
        return max(a / b, b / a)
    }

    /// Median amount by which the frame's marks exceed whole units (a receiver stretches marks).
    private func markSkew(_ d: [Int], from start: Int) -> Int {
        var residuals: [Int] = []
        var index = start
        while index < d.count {
            residuals.append(d[index] - max(1, Int((Double(d[index]) / Double(unit)).rounded())) * unit)
            if index + 1 >= d.count || d[index + 1] >= gapThreshold { break }
            index += 2
        }
        guard !residuals.isEmpty else { return 0 }
        return min(max(residuals.sorted()[residuals.count / 2], -unit / 3), unit / 3)
    }
}

/// `count` bits of `value`, most significant first.
func msbFirst(_ value: UInt32, _ count: Int) -> [Bool] {
    (0..<count).map { value >> UInt32(count - 1 - $0) & 1 == 1 }
}

/// The value of bits written most significant first.
func msbValue<S: Sequence>(_ bits: S) -> UInt32 where S.Element == Bool {
    bits.reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
}
