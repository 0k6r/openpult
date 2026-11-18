import Foundation

/// A protocol family: turns parsed codes into signals and recognizes them in captured durations.
public protocol IRCodec {
    /// The protocol IDs this codec encodes and may return from `decode`.
    static var protocols: [IRProtocolID] { get }

    /// The signal for one press. `toggle` sets the RC5/RC6 toggle bit and is ignored elsewhere.
    static func encode(_ code: IRCode, toggle: Bool) -> IRSignal

    /// Reads one press from the start of `durations` (mark first). `consumed` counts the durations used,
    /// including the gap after the frame and any repeat codes that belong to it.
    static func decode(_ durations: [Int]) -> (code: IRCode, toggle: Bool, consumed: Int)?
}

public enum IRCodecs {
    static let all: [any IRCodec.Type] = [
        NECCodec.self, Samsung32Codec.self, SIRCCodec.self, RC5Codec.self, RC6Codec.self,
        KaseikyoCodec.self, RCACodec.self, PioneerCodec.self,
    ]

    public static func codec(for id: IRProtocolID) -> any IRCodec.Type {
        switch id {
        case .nec, .necext, .nec42, .nec42ext: NECCodec.self
        case .samsung32: Samsung32Codec.self
        case .sirc, .sirc15, .sirc20: SIRCCodec.self
        case .rc5, .rc5x: RC5Codec.self
        case .rc6: RC6Codec.self
        case .kaseikyo: KaseikyoCodec.self
        case .rca: RCACodec.self
        case .pioneer: PioneerCodec.self
        }
    }

    public static func signal(for command: IRCommand, toggle: Bool) -> IRSignal {
        switch command {
        case .code(let code): codec(for: code.proto).encode(code, toggle: toggle)
        case .raw(let signal): signal
        }
    }

    /// Protocols with a toggle bit that tells a new press from a held key.
    public static func usesToggle(_ id: IRProtocolID) -> Bool {
        id == .rc5 || id == .rc5x || id == .rc6
    }
}

/// RC5/RC6 toggle bits, one per remote (protocol family + address): flipped on every new press, kept while the
/// key is held or a held key's signal is sent again.
public struct IRToggleState: Sendable {
    private struct Remote: Hashable, Sendable {
        let proto: IRProtocolID
        let address: UInt32
    }

    private var bits: [Remote: Bool] = [:]

    public init() {}

    public mutating func toggle(for code: IRCode, newPress: Bool) -> Bool {
        guard IRCodecs.usesToggle(code.proto) else { return false }
        let remote = Remote(proto: code.proto == .rc5x ? .rc5 : code.proto, address: code.address)
        if newPress {
            bits[remote] = !(bits[remote] ?? false)
        }
        return bits[remote] ?? false
    }
}
