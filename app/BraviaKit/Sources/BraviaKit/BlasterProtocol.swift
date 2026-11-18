import Foundation
import PultIR

/// Wire format of the openpult IR bridge. Mirrors firmware/PROTOCOL.md (protocol v2).
public enum BlasterProtocol {
    public static let serviceUUID = "7B2A0001-5C1E-4F6B-9D3A-8E4F1C2B7A10"
    public static let commandUUID = "7B2A0002-5C1E-4F6B-9D3A-8E4F1C2B7A10"
    public static let statusUUID = "7B2A0003-5C1E-4F6B-9D3A-8E4F1C2B7A10"
    public static let captureUUID = "7B2A0004-5C1E-4F6B-9D3A-8E4F1C2B7A10"
    public static let batteryServiceUUID = "180F"
    public static let batteryLevelUUID = "2A19"
    public static let deviceInfoServiceUUID = "180A"
    public static let firmwareRevisionUUID = "2A26"

    /// Sony needs at least three identical frames for a key press.
    public static let defaultFrames: UInt8 = 3

    /// Legacy v1 SEND of a Sony SIRC code (bridges with protocol 1).
    public static func send(_ code: SIRCCode, frames: UInt8 = defaultFrames, hold: Bool = false) -> Data {
        Data([
            0x01,
            hold ? 0x01 : 0x00,
            code.bits.rawValue,
            UInt8(code.device & 0xFF),
            UInt8(code.device >> 8),
            code.command,
            min(max(frames, 3), 20),
        ])
    }

    public static let stop = Data([0x02])
    public static let enterBootloader = Data([0xF0, 0x55, 0xAA])
    public static let learnStop = Data([0x21])

    public static func learnStart(timeoutSeconds: Int) -> Data {
        Data([0x20, UInt8(min(max(timeoutSeconds, 1), 60))])
    }
}

/// ATT application errors returned by the bridge for a rejected command.
public enum BlasterRejection: UInt8, Sendable {
    case malformed = 0x80
    case queueFull = 0x81
    case unsupportedBits = 0x82
    case nothingToHold = 0x83
    case unsupportedSignal = 0x84
    case unavailable = 0x85
}

public struct BlasterStatus: Equatable, Sendable {
    public struct Capabilities: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let play = Capabilities(rawValue: 1 << 0)
        public static let learn = Capabilities(rawValue: 1 << 1)
        public static let legacySend = Capabilities(rawValue: 1 << 2)
        public static let uf2Bootloader = Capabilities(rawValue: 1 << 3)
    }

    public var protocolVersion: UInt8
    public var isTransmitting: Bool
    public var isPairingWindowOpen: Bool
    public var isBatteryLow: Bool
    public var isLearning: Bool
    public var isExternallyPowered: Bool
    public var batteryMillivolts: Int
    public var queueFree: Int
    public var lastError: UInt8
    public var uptimeMinutes: Int
    /// `nil` for protocol 1 bridges (8-byte status).
    public var capabilities: Capabilities?
    public var maxBlob: Int?

    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        protocolVersion = bytes[0]
        isTransmitting = bytes[1] & 0x01 != 0
        isPairingWindowOpen = bytes[1] & 0x02 != 0
        isBatteryLow = bytes[1] & 0x04 != 0
        isLearning = bytes[1] & 0x08 != 0
        isExternallyPowered = bytes[1] & 0x10 != 0
        batteryMillivolts = Int(bytes[2]) | Int(bytes[3]) << 8
        queueFree = Int(bytes[4])
        lastError = bytes[5]
        uptimeMinutes = Int(bytes[6]) | Int(bytes[7]) << 8
        if bytes.count >= 12 {
            capabilities = Capabilities(rawValue: bytes[8])
            maxBlob = Int(bytes[9]) | Int(bytes[10]) << 8
        }
    }

    /// Protocol 2 bridges play universal signals.
    public var supportsPlay: Bool { protocolVersion >= 2 }
}

/// What a key press sends: the universal signal, plus the legacy Sony code for protocol 1 bridges.
public struct BlasterSignal: Equatable, Sendable {
    public var signal: IRSignal
    public var legacy: SIRCCode?

    public init(signal: IRSignal, legacy: SIRCCode? = nil) {
        self.signal = signal
        self.legacy = legacy
    }
}

extension SIRCCode {
    /// The same code in the protocol-neutral form (Flipper conventions: SIRC address = device field).
    public var irCode: IRCode {
        let proto: IRProtocolID
        switch bits {
        case .b12: proto = .sirc
        case .b15: proto = .sirc15
        case .b20: proto = .sirc20
        }
        return IRCode(proto: proto, address: UInt32(device), command: UInt32(command))
    }

    public init?(_ code: IRCode) {
        let bits: Bits
        switch code.proto {
        case .sirc: bits = .b12
        case .sirc15: bits = .b15
        case .sirc20: bits = .b20
        default: return nil
        }
        guard code.address <= UInt32(UInt16.max), code.command <= 127 else { return nil }
        self.init(bits: bits, device: UInt16(code.address), command: UInt8(code.command))
    }
}
