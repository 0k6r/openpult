import Foundation

public enum IRCaptureResult: Equatable, Sendable {
    /// Captured durations (µs, mark first). `truncated`: the bridge stopped at 512 durations or 1 s.
    case durations([Int], truncated: Bool)
    /// Learning timed out without a signal.
    case timeout
    /// A capture was lost in transit (missing fragment, bad length or varint); start learning again. A capture
    /// whose last fragment is lost yields nothing at all, so the app still needs its own timeout.
    case corrupted
}

/// Reassembles Capture characteristic notifications:
/// `[capture_id][frag: bit7 LAST, bits 6..0 index]`, fragment 0 then `[flags][count u16 LE]`, then LEB128 durations.
public struct IRCaptureAssembler: Sendable {
    private var captureID: UInt8?
    private var nextIndex = 0
    private var flags: UInt8 = 0
    private var expectedCount = 0
    private var payload: [UInt8] = []
    /// The capture already reported as `.corrupted`, whose remaining fragments are dropped quietly.
    private var lostID: UInt8?

    public init() {}

    /// Feeds one notification; returns a result once a capture is complete, lost, or reports a timeout.
    /// A capture whose start was missed is reported as `.corrupted` at its last fragment.
    public mutating func append(_ notification: Data) -> IRCaptureResult? {
        let bytes = [UInt8](notification)
        guard bytes.count >= 2 else { return nil }
        let (id, index, isLast) = (bytes[0], Int(bytes[1] & 0x7F), bytes[1] & 0x80 != 0)
        if index == 0 {
            guard bytes.count >= 5 else { return finish(.corrupted, lost: id) }
            if bytes[2] & 0x02 != 0 { return finish(.timeout) }
            (captureID, flags, nextIndex, lostID) = (id, bytes[2], 1, nil)
            expectedCount = Int(bytes[3]) | Int(bytes[4]) << 8
            payload = Array(bytes[5...])
        } else {
            guard captureID != nil else { return isLast && id != lostID ? finish(.corrupted, lost: id) : nil }
            guard captureID == id, index == nextIndex else { return finish(.corrupted, lost: id) }
            payload += bytes[2...]
            nextIndex += 1
        }
        guard isLast else { return nil }
        var offset = 0
        var durations: [Int] = []
        while offset < payload.count {
            guard let duration = LEB128.read(payload, at: &offset) else { return finish(.corrupted, lost: id) }
            durations.append(duration)
        }
        guard durations.count == expectedCount else { return finish(.corrupted, lost: id) }
        return finish(.durations(durations, truncated: flags & 0x01 != 0))
    }

    private mutating func finish(_ result: IRCaptureResult, lost: UInt8? = nil) -> IRCaptureResult {
        self = IRCaptureAssembler()
        lostID = lost
        return result
    }
}
