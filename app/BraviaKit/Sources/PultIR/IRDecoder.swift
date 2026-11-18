import Foundation

/// Turns a learned capture into a command: a recognized code, or a normalized raw signal.
public enum IRDecoder {
    /// Carrier assumed for raw signals: a demodulating receiver cannot measure it.
    static let rawCarrierHz = 38_000
    static let rawMinRepeats = 2
    /// Gap appended to a raw frame when the capture ends right after its last mark.
    static let rawDefaultGap = 40_000

    /// Every codec tries to read a frame at the current position and the best fit consumes it; where none fits,
    /// the position moves on by one mark/space pair. The result is a code when all recognized frames agree (toggle
    /// aside) and outnumber the unrecognized stretches of half a frame or more (a frame spoiled by interference);
    /// otherwise a raw signal. An empty capture gives an empty raw signal, which `IRSignalBlob.encode` rejects.
    public static func decode(_ captured: [Int]) -> IRCommand {
        let durations = sanitized(captured)
        var codes: [IRCode] = []
        var firstFrame: [Int] = []
        var unrecognized: [Int] = []   // lengths of the stretches no codec read
        var skipped = 0
        var position = 0
        while position < durations.count {
            let rest = Array(durations[position...])
            guard let match = bestMatch(rest) else {
                skipped += min(2, rest.count)
                position += 2
                continue
            }
            if skipped > 0 { unrecognized.append(skipped) }
            skipped = 0
            if let first = codes.first, match.code != first, match.consumed == rest.count,
               rest.count < firstFrame.count, zip(rest, firstFrame).allSatisfy({ isClose($0, to: $1) }) {
                // The capture stopped inside a frame, which then reads as another code (SIRC15 cut to 12 bits).
                unrecognized.append(rest.count)
            } else {
                if codes.isEmpty { firstFrame = match.frame }
                codes.append(match.code)
            }
            position += match.consumed
        }
        if skipped > 0 { unrecognized.append(skipped) }
        if let first = codes.first, codes.allSatisfy({ $0 == first }),
           codes.count > unrecognized.filter({ 2 * $0 >= firstFrame.count }).count {
            return .code(first)
        }
        return .raw(normalize(durations))
    }

    /// Whether two learned commands are the same button: equal codes, or first frames that match duration by
    /// duration (gaps and toggle bits aside). A code is compared with a raw signal through its encoded frame.
    public static func sameCommand(_ a: IRCommand, _ b: IRCommand) -> Bool {
        if case let (.code(x), .code(y)) = (a, b) { return x == y }
        func firstFrames(_ command: IRCommand) -> [ArraySlice<Int>] {
            [false, true].map { IRCodecs.signal(for: command, toggle: $0).firstFrame.dropLast() }
        }
        return firstFrames(a).contains { first in
            firstFrames(b).contains { second in
                !first.isEmpty && first.count == second.count && zip(first, second).allSatisfy(isSimilar)
            }
        }
    }

    // MARK: - Recognition

    private static func bestMatch(_ d: [Int]) -> (code: IRCode, consumed: Int, frame: [Int])? {
        var best: (code: IRCode, consumed: Int, frame: [Int], misfit: Double)?
        for codec in IRCodecs.all {
            guard let match = codec.decode(d), match.consumed > 0 else { continue }
            let frame = codec.encode(match.code, toggle: match.toggle).firstFrame
            let misfit = misfit(frame, d)
            if misfit < best?.misfit ?? .infinity {
                best = (match.code, match.consumed, frame, misfit)
            }
        }
        return best.map { ($0.code, $0.consumed, $0.frame) }
    }

    /// How far a capture is from an encoded frame, per (mark, space) pair, gap excluded: the relative error of the
    /// pair's period, which mark/space skew does not change, plus the error of the mark's share of it, which skew
    /// shifts alike for look-alikes. Separates NEC from Pioneer (periods) and SIRC from RC5 (shares).
    private static func misfit(_ frame: [Int], _ d: [Int]) -> Double {
        let pairs = min(frame.count, d.count) / 2 - 1
        guard pairs > 0 else { return .infinity }
        let total = (0..<pairs).reduce(0.0) { sum, pair in
            let (mark, period) = (Double(d[2 * pair]), Double(max(d[2 * pair] + d[2 * pair + 1], 1)))
            let (expectedMark, expectedPeriod) = (Double(frame[2 * pair]), Double(frame[2 * pair] + frame[2 * pair + 1]))
            return sum + abs(period - expectedPeriod) / expectedPeriod + abs(mark / period - expectedMark / expectedPeriod)
        }
        return total / Double(pairs)
    }

    // MARK: - Raw signals

    /// Durations clustered into at most 16 values and split into frames at the longest pauses, then arranged as
    /// intro + repeat (see `sections`) within what the bridge plays: marks up to 30 ms, sections up to 1 s and 512
    /// durations.
    static func normalize(_ captured: [Int]) -> IRSignal {
        var d = sanitized(captured).enumerated().map { index, duration in
            min(max(duration, 1), index % 2 == 0 ? IRSignalBlob.maxMark : IRSignalBlob.durations.upperBound)
        }
        if d.count % 2 == 1 {
            d.append(frameBreaks(d).map { d[$0] }.max() ?? rawDefaultGap)
        }
        d = clustered(d, limit: IRSignalBlob.maxTable)
        var frames: [[Int]] = []
        var start = 0
        for end in frameBreaks(d) + [d.count - 1] where end >= start {
            frames.append(Array(d[start...end]))
            start = end + 1
        }
        let (intro, repeatSection) = sections(frames)
        return IRSignal(carrierHz: rawCarrierHz, intro: playable(intro), repeat: playable(repeatSection),
                        minRepeats: rawMinRepeats)
    }

    /// The frames as intro + repeat. The shortest period of one or two frames after at most one intro frame wins
    /// (A A A, I R R R, A B A B), the last frame may be cut short; otherwise the first frame is the intro and the
    /// second the repeat, or the first alone repeats if the second equals it.
    static func sections(_ frames: [[Int]]) -> (intro: [Int], repeat: [Int]) {
        guard let first = frames.first else { return ([], []) }
        func same(_ index: Int, as earlier: Int) -> Bool {
            let (frame, model) = (frames[index].dropLast(), frames[earlier].dropLast())
            return frame == model || (index == frames.count - 1 && frame.count < model.count && model.starts(with: frame))
        }
        for length in 1...2 {
            for introCount in 0...1 where introCount + 2 * length <= frames.count
                && (introCount + length..<frames.count).allSatisfy({ same($0, as: $0 - length) }) {
                return (frames[..<introCount].flatMap { $0 }, frames[introCount..<introCount + length].flatMap { $0 })
            }
        }
        if frames.count < 2 || frames[1].dropLast() == first.dropLast() { return ([], first) }
        return (first, frames[1])
    }

    /// Drops trailing (space, mark) pairs of a section until it fits 1 s and 512 durations; the gap stays.
    private static func playable(_ section: [Int]) -> [Int] {
        guard let gap = section.last else { return section }
        var body = Array(section.dropLast())
        while body.count > 1 && (body.count >= IRSignalBlob.maxSymbols / 2
                                 || body.reduce(0, +) + gap > IRSignalBlob.maxSection) {
            body.removeLast(2)
        }
        return body + [gap]
    }

    /// Indices of the spaces that end a frame: pauses of at least 6 ms (above a jittered 4.5 ms NEC header space)
    /// beyond the widest jump, of 1.4× or more, between pause lengths. Without such a jump the capture is one frame.
    static func frameBreaks(_ d: [Int]) -> [Int] {
        let spaceIndices = Array(stride(from: 1, to: d.count, by: 2))
        let lengths = Set(spaceIndices.map { d[$0] }).sorted()
        var threshold = Int.max
        var widest = 1.4
        for (shorter, longer) in zip([0] + lengths, lengths) where longer >= 6000 {
            let jump = shorter == 0 ? Double.infinity : Double(longer) / Double(shorter)
            if jump >= widest {
                (widest, threshold) = (jump, longer)
            }
        }
        return spaceIndices.filter { d[$0] >= threshold }
    }

    /// Replaces every duration with its cluster's mean. Marks and spaces cluster separately, since a receiver skews
    /// them in opposite directions. Sorted values are split at their widest gap until every value of a cluster lies
    /// within ±25 % (at least ±150 µs) of its mean; then the closest clusters of a kind merge until at most `limit`
    /// distinct values remain.
    static func clustered(_ d: [Int], limit: Int) -> [Int] {
        func mean(_ group: ArraySlice<Int>) -> Int {
            max(1, Int((Double(group.reduce(0) { $0 + d[$1] }) / Double(group.count)).rounded()))
        }
        func fits(_ group: ArraySlice<Int>) -> Bool {
            let center = mean(group)
            let tolerance = max(center / 4, 150)
            return d[group.last!] - center <= tolerance && center - d[group.first!] <= tolerance
        }
        var groups: [ArraySlice<Int>] = []   // indices into d, sorted by duration
        var pending = (0..<2).map { parity in
            ArraySlice(stride(from: parity, to: d.count, by: 2).sorted { d[$0] < d[$1] })
        }.filter { !$0.isEmpty }
        while let group = pending.popLast() {
            if fits(group) {
                groups.append(group)
                continue
            }
            let cut = (group.startIndex + 1..<group.endIndex).max {
                Double(d[group[$0]]) / Double(max(d[group[$0 - 1]], 1))
                    < Double(d[group[$1]]) / Double(max(d[group[$1 - 1]], 1))
            }!
            pending += [group[..<cut], group[cut...]]
        }
        // Merge neighbours of the same kind only, so that marks stay within the 30 ms limit.
        groups.sort { mean($0) < mean($1) }
        func ratio(_ pair: (Int, Int)) -> Double { Double(mean(groups[pair.1])) / Double(mean(groups[pair.0])) }
        while Set(groups.map(mean)).count > limit {
            let neighbours = (0..<2).flatMap { parity -> [(Int, Int)] in
                let kind = groups.indices.filter { groups[$0].first! % 2 == parity }
                return Array(zip(kind, kind.dropFirst()))
            }
            let (lower, upper) = neighbours.min { ratio($0) < ratio($1) }!
            groups[lower] = ArraySlice(groups[lower] + groups.remove(at: upper))
            groups.sort { mean($0) < mean($1) }
        }
        var out = d
        for group in groups {
            let value = mean(group)
            for index in group { out[index] = value }
        }
        return out
    }

    /// Two captures of one duration: within 1.4× of each other (±15 % jitter on both), or 150 µs.
    private static func isSimilar(_ a: Int, _ b: Int) -> Bool {
        abs(a - b) <= 150 || Double(max(a, b)) <= Double(min(a, b)) * 1.4
    }
}
