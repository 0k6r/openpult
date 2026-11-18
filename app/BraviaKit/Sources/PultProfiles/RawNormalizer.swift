import Foundation

/// Limits of the protocol v2 signal blob (firmware/PROTOCOL.md, "Signal blob"); PultIR's `IRSignalBlob` enforces
/// the same numbers (checked by tests).
enum BlobLimits {
    static let carrier = 20_000...65_535
    static let duty = 10...50
    static let symbolsMin = 2
    static let symbolsMax = 1024
    static let markMax = 30_000
    static let sectionMax = 1_000_000
    static let durationMax = 500_000
    static let tableMax = 16
    static let blobMax = 576
    static let blobHeader = 9
}

/// Raw recordings -> intro / repeat sections (import_flipper_irdb.py, "Raw signals").
enum RawNormalizer {
    static let frameGap = 20_000           // a space longer than this separates frames
    static let tailGap = 40_000            // appended when a recording ends with a mark
    static let clusterTolerance = 0.05     // every duration stays within +-5 % of its cluster value
    static let frameMatchTolerance = 0.25
    static let frameMatchMin = 200         // first marks of a recording are often shortened by the receiver
    static let durationMin = 50            // shorter than two carrier periods: receiver noise, not a signal
    static let maxFrames = 64              // more frames than this cannot fit a 1 s section anyway

    /// `cluster_map`: every duration -> the count-weighted mean of its cluster; all members stay within tolerance.
    static func clusterMap(_ values: [Int], tolerance: Double = clusterTolerance) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        func center(_ total: Int, _ weighted: Int) -> Int { Py.floorDiv(2 * weighted + total, 2 * total) }
        // Greedy over sorted values with running sums. The center lies between the smallest and the largest
        // member, so checking those two bounds every member.
        var clusters: [(members: [Int], total: Int, weighted: Int)] = []
        for value in counts.keys.sorted() {
            let n = counts[value]!
            if let last = clusters.last {
                let t = last.total + n, w = last.weighted + value * n
                let c = center(t, w)
                let limit = tolerance * Double(c)
                if Double(abs(last.members[0] - c)) <= limit && Double(abs(value - c)) <= limit {
                    clusters[clusters.count - 1].members.append(value)
                    clusters[clusters.count - 1].total = t
                    clusters[clusters.count - 1].weighted = w
                    continue
                }
            }
            clusters.append(([value], n, value * n))
        }
        var mapping: [Int: Int] = [:]
        for cluster in clusters {
            let c = center(cluster.total, cluster.weighted)
            for v in cluster.members {
                mapping[v] = c
            }
        }
        return mapping
    }

    /// `split_frames`: split an even mark/space sequence after every space longer than `frameGap`.
    static func splitFrames(_ seq: [Int]) -> [[Int]] {
        var frames: [[Int]] = []
        var start = 0
        for i in stride(from: 1, to: seq.count, by: 2) where seq[i] > frameGap {
            frames.append(Array(seq[start...i]))
            start = i + 1
        }
        if start < seq.count {
            frames.append(Array(seq[start...]))
        }
        return frames
    }

    private static func close(_ x: Int, _ y: Int) -> Bool {
        Double(abs(x - y)) <= max(Double(frameMatchMin), frameMatchTolerance * Double(max(x, y)))
    }

    /// `frames_match`: same structure and timings within tolerance; the trailing gap is not compared.
    static func framesMatch(_ a: [Int], _ b: [Int]) -> Bool {
        guard a.count == b.count else { return false }
        return (0..<max(a.count - 1, 0)).allSatisfy { close(a[$0], b[$0]) }
    }

    /// `is_fragment`: a last frame cut off by the end of the recording, a shorter copy of the start of `prev`.
    static func isFragment(_ tail: [Int], _ prev: [Int]) -> Bool {
        guard tail.count < prev.count else { return false }
        return (0..<max(tail.count - 1, 0)).allSatisfy { close(tail[$0], prev[$0]) }
    }

    /// `trim_tail`: drop trailing lone marks (when the recording has a real frame) and one cut-off last frame.
    static func trimTail(_ input: [[Int]]) -> [[Int]] {
        var frames = input
        while frames.count >= 2 && frames[frames.count - 1].count == 2 && frames.dropLast().contains(where: { $0.count > 2 }) {
            frames.removeLast()
        }
        if frames.count >= 2 && isFragment(frames[frames.count - 1], frames[frames.count - 2]) {
            frames.removeLast()
        }
        return frames
    }

    /// `raw_sections`: (intro, repeat) for one recorded press; `seq` has even length and ends with a space.
    ///
    /// - A A A      -> repeat A
    /// - A B B, A B -> intro A, repeat B (e.g. NEC frame + repeat code)
    /// - A B A B    -> repeat A B (frame pairs such as Sharp's normal + inverted frame)
    /// - otherwise  -> the whole recording as the repeat section.
    static func rawSections(_ seq: [Int]) -> (intro: [Int], repeat: [Int]) {
        var frames = splitFrames(seq)
        if frames.count > maxFrames {
            return ([], seq)
        }
        frames = trimTail(frames)
        if frames.count == 1 {
            return ([], frames[0])
        }
        for skip in [0, 1] {
            let body = Array(frames[skip...])
            for period in 1...max(body.count, 1) where period <= body.count {
                if period > 1 && body.count < 2 * period {
                    break
                }
                if (period..<body.count).allSatisfy({ framesMatch(body[$0], body[$0 % period]) }) {
                    return (skip == 1 ? frames[0] : [], body[..<period].flatMap { $0 })
                }
            }
        }
        return ([], frames.flatMap { $0 })
    }

    static func leb128Length(_ value: Int) -> Int {
        var n = 1
        var v = value
        while v >= 0x80 {
            v >>= 7
            n += 1
        }
        return n
    }

    /// `blob_size`: the size of the protocol v2 blob for these sections.
    static func blobSize(intro: [Int], repeat: [Int]) -> Int {
        var seen = Set<Int>()
        var table = 0
        for v in intro + `repeat` where seen.insert(v).inserted {
            table += leb128Length(v)
        }
        return BlobLimits.blobHeader + table + (intro.count + 1) / 2 + (`repeat`.count + 1) / 2
    }

    /// `check_sections`: protocol v2 limits; returns a skip reason or nil.
    static func checkSections(carrier: Int, duty: Int, intro: [Int], repeat: [Int]) -> String? {
        let all = intro + `repeat`
        if !BlobLimits.carrier.contains(carrier) {
            return "raw: carrier outside 20000..65535 Hz"
        }
        if !BlobLimits.duty.contains(duty) {
            return "raw: duty cycle outside 10..50 %"
        }
        if all.count < BlobLimits.symbolsMin {
            return "raw: fewer than 2 durations"
        }
        if all.count > BlobLimits.symbolsMax {
            return "raw: more than 1024 durations"
        }
        if intro.count % 2 != 0 || `repeat`.count % 2 != 0 {
            return "raw: section with odd length"
        }
        let marks = stride(from: 0, to: intro.count, by: 2).map { intro[$0] }
            + stride(from: 0, to: `repeat`.count, by: 2).map { `repeat`[$0] }
        if marks.contains(where: { $0 > BlobLimits.markMax }) {
            return "raw: mark longer than 30 ms"
        }
        if all.contains(where: { !(durationMin...BlobLimits.durationMax).contains($0) }) {
            return "raw: duration outside 50..500000 us"
        }
        if intro.reduce(0, +) > BlobLimits.sectionMax || `repeat`.reduce(0, +) > BlobLimits.sectionMax {
            return "raw: section longer than 1 s"
        }
        if Set(all).count > BlobLimits.tableMax {
            return "raw: more than 16 distinct durations after clustering"
        }
        if blobSize(intro: intro, repeat: `repeat`) > BlobLimits.blobMax {
            return "raw: blob larger than 576 bytes"
        }
        return nil
    }

    /// `normalize_raw`: a Flipper raw recording -> a raw command or a skip reason.
    static func normalizeRaw(frequency: Int, dutyCycle: Double, data: [Int]) -> Result<ProfileCommand, SkipReason> {
        let carrier = frequency
        let duty = Int(dutyCycle <= 1 ? Py.round(dutyCycle * 100) : Py.round(dutyCycle))
        if data.isEmpty {
            return .failure("raw: empty data")
        }
        if data.count > ImportLimits.maxRawDurations {
            return .failure("raw: recording longer than 4096 durations")
        }
        if data.contains(where: { $0 <= 0 }) {
            return .failure("raw: non-positive duration")
        }
        var seq = data
        if seq.count % 2 != 0 {
            seq.append(tailGap)                    // Flipper recordings end with a mark
        } else if seq[seq.count - 1] <= frameGap {
            seq[seq.count - 1] = tailGap           // cut off inside a frame: give the press its trailing gap
        }
        if splitFrames(seq).allSatisfy({ $0.count == 2 }) {
            return .failure("raw: isolated pulses only (noise)")
        }
        let sections = rawSections(seq)
        let mapping = clusterMap(sections.intro + sections.repeat)
        let intro = sections.intro.map { mapping[$0]! }
        let rep = sections.repeat.map { mapping[$0]! }
        if let reason = checkSections(carrier: carrier, duty: duty, intro: intro, repeat: rep) {
            return .failure(SkipReason(reason))
        }
        return .success(.raw(frequency: carrier, duty: duty, intro: intro, repeat: rep))
    }
}

/// Why a code or a file was skipped; the text is the key of the import report.
struct SkipReason: Error, Equatable, ExpressibleByStringLiteral {
    let text: String

    init(_ text: String) { self.text = text }
    init(stringLiteral text: String) { self.text = text }
}
