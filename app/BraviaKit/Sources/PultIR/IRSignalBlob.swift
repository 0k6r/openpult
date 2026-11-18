import Foundation

/// The protocol v2 signal blob and the PLAY / HOLD commands that carry it (firmware/PROTOCOL.md).
public enum IRSignalBlob {
    public static let maxBlobBytes = 576
    /// Largest Command write the bridge accepts (ATT MTU 247 − 3); `playWrites` never exceeds it.
    public static let maxWriteBytes = 244

    static let maxTable = 16
    static let maxSymbols = 1024
    static let durations = 1...500_000
    static let maxMark = 30_000
    static let maxSection = 1_000_000
    static let playOpcode: UInt8 = 0x10
    static let holdOpcode: UInt8 = 0x11

    /// Encodes a signal as a blob. The duration table is built in order of first appearance, intro first.
    public static func encode(_ signal: IRSignal) throws -> Data {
        try validate(signal)
        var table: [Int] = []
        var index: [Int: UInt8] = [:]
        for duration in signal.intro + signal.repeat where index[duration] == nil {
            index[duration] = UInt8(table.count)
            table.append(duration)
        }
        var out: [UInt8] = []
        appendU16(signal.carrierHz, to: &out)
        out += [UInt8(signal.dutyPercent), UInt8(signal.minRepeats), UInt8(table.count)]
        appendU16(signal.intro.count, to: &out)
        appendU16(signal.repeat.count, to: &out)
        for duration in table {
            LEB128.append(duration, to: &out)
        }
        for section in [signal.intro, signal.repeat] {
            for pair in stride(from: 0, to: section.count, by: 2) {
                out.append(index[section[pair]]! << 4 | index[section[pair + 1]]!)
            }
        }
        guard out.count <= maxBlobBytes else { throw IRSignalError.tooLong }
        return Data(out)
    }

    /// Parses a blob and applies the same limits as `encode`.
    public static func decode(_ blob: Data) throws -> IRSignal {
        guard blob.count <= maxBlobBytes else { throw IRSignalError.tooLong }
        let bytes = [UInt8](blob)
        var offset = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count <= bytes.count - offset else { throw IRSignalError.malformedBlob }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }
        func u16() throws -> Int {
            let pair = try take(2)
            return Int(pair.first!) | Int(pair.last!) << 8
        }
        let carrier = try u16()
        let header = try take(3)
        let (duty, minRepeats, tableCount) = (Int(header.first!), Int(header.dropFirst().first!), Int(header.last!))
        let introCount = try u16()
        let repeatCount = try u16()
        guard (1...maxTable).contains(tableCount) else { throw IRSignalError.malformedBlob }
        let table = try (0..<tableCount).map { _ -> Int in
            guard let value = LEB128.read(bytes, at: &offset) else { throw IRSignalError.malformedBlob }
            guard durations.contains(value) else { throw IRSignalError.durationOutOfRange }
            return value
        }
        func section(_ count: Int) throws -> [Int] {
            let packed = Array(try take((count + 1) / 2))
            return try (0..<count).map { symbol in
                let nibble = Int(symbol % 2 == 0 ? packed[symbol / 2] >> 4 : packed[symbol / 2] & 0x0F)
                guard nibble < table.count else { throw IRSignalError.malformedBlob }
                return table[nibble]
            }
        }
        let intro = try section(introCount)
        let repeatSection = try section(repeatCount)
        guard offset == bytes.count else { throw IRSignalError.malformedBlob }
        let signal = IRSignal(carrierHz: carrier, dutyPercent: duty, intro: intro, repeat: repeatSection,
                              minRepeats: minRepeats)
        try validate(signal)
        return signal
    }

    /// Splits a blob into PLAY writes: `10 00 <sig_id> <frag>` + chunk, `frag` = index | 0x80 on the last one.
    /// `maxWrite` is the usable write length (capped at `maxWriteBytes`); it must leave room for the 4-byte header
    /// and keep the fragment count within 128.
    public static func playWrites(_ blob: Data, sigID: UInt8, maxWrite: Int) -> [Data] {
        let chunk = min(maxWrite, maxWriteBytes) - 4
        precondition(chunk > 0, "maxWrite must exceed the 4-byte PLAY header")
        let bytes = [UInt8](blob)
        let parts = bytes.isEmpty ? [[]] : stride(from: 0, to: bytes.count, by: chunk).map {
            Array(bytes[$0..<min($0 + chunk, bytes.count)])
        }
        precondition(parts.count <= 128, "too many PLAY fragments")
        return parts.enumerated().map { number, part in
            let frag = UInt8(number) | (number == parts.count - 1 ? 0x80 : 0)
            return Data([playOpcode, 0x00, sigID, frag] + part)
        }
    }

    /// HOLD: extend the signal `sigID` on air to `count` repeat units.
    public static func hold(sigID: UInt8, count: UInt8) -> Data {
        Data([holdOpcode, sigID, count])
    }

    /// HOLD count for a signal: clamp(ceil(180 ms / repeat unit) + 1, 2, 20).
    public static func holdCount(for signal: IRSignal) -> UInt8 {
        let unit = signal.repeatUnitMicros
        guard unit > 0 else { return 20 }
        return UInt8(min(max((180_000 + unit - 1) / unit + 1, 2), 20))
    }

    static func validate(_ signal: IRSignal) throws {
        let all = signal.intro + signal.repeat
        guard !all.isEmpty else { throw IRSignalError.emptySignal }
        guard signal.intro.count % 2 == 0, signal.repeat.count % 2 == 0 else { throw IRSignalError.oddSection }
        guard (20_000...65_535).contains(signal.carrierHz) else { throw IRSignalError.carrierOutOfRange }
        guard signal.dutyPercent == 0 || (10...50).contains(signal.dutyPercent) else {
            throw IRSignalError.dutyOutOfRange
        }
        guard (0...20).contains(signal.minRepeats) else { throw IRSignalError.repeatsOutOfRange }
        guard all.allSatisfy(durations.contains) else { throw IRSignalError.durationOutOfRange }
        for section in [signal.intro, signal.repeat] {
            guard stride(from: 0, to: section.count, by: 2).allSatisfy({ section[$0] <= maxMark }) else {
                throw IRSignalError.markTooLong
            }
            guard section.reduce(0, +) <= maxSection else { throw IRSignalError.tooLong }
        }
        guard all.count <= maxSymbols else { throw IRSignalError.tooLong }
        guard Set(all).count <= maxTable else { throw IRSignalError.tooManyDistinctDurations }
    }

    private static func appendU16(_ value: Int, to out: inout [UInt8]) {
        out += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
    }
}

/// Unsigned LEB128 varints (blob table, capture durations).
enum LEB128 {
    static func append(_ value: Int, to out: inout [UInt8]) {
        var rest = value
        repeat {
            let low = UInt8(rest & 0x7F)
            rest >>= 7
            out.append(rest == 0 ? low : low | 0x80)
        } while rest != 0
    }

    /// Reads one varint at `offset` and advances it; nil if it is truncated or longer than 5 bytes.
    static func read(_ bytes: [UInt8], at offset: inout Int) -> Int? {
        var value = 0
        for shift in stride(from: 0, to: 35, by: 7) {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]
            offset += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }
}
