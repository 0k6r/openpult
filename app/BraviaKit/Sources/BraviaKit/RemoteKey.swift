import Foundation

/// Buttons of the physical remote, mapped to IRCC codes.
public enum RemoteKey: String, CaseIterable, Sendable {
    case power, powerOff, wakeUp, input, home, back, options
    case up, down, left, right, confirm
    case volumeUp, volumeDown, mute, channelUp, channelDown
    case play, pause, stop, rewind, forward, previous, next
    case red, green, yellow, blue
    case num0, num1, num2, num3, num4, num5, num6, num7, num8, num9
    case display, subtitles, audioTrack, guide
    case hdmi1, hdmi2, hdmi3, hdmi4

    /// Names the TV may use in `getRemoteControllerInfo`, in priority order.
    public var tvNames: [String] {
        switch self {
        case .power: return ["TvPower", "Power"]
        case .powerOff: return ["PowerOff"]
        case .wakeUp: return ["WakeUp"]
        case .input: return ["Input", "TvInput"]
        case .home: return ["Home"]
        case .back: return ["Return", "Back"]
        case .options: return ["Options", "ActionMenu"]
        case .up: return ["Up"]
        case .down: return ["Down"]
        case .left: return ["Left"]
        case .right: return ["Right"]
        case .confirm: return ["Confirm"]
        case .volumeUp: return ["VolumeUp"]
        case .volumeDown: return ["VolumeDown"]
        case .mute: return ["Mute"]
        case .channelUp: return ["ChannelUp"]
        case .channelDown: return ["ChannelDown"]
        case .play: return ["Play"]
        case .pause: return ["Pause"]
        case .stop: return ["Stop"]
        case .rewind: return ["Rewind"]
        case .forward: return ["Forward"]
        case .previous: return ["Prev"]
        case .next: return ["Next"]
        case .red: return ["Red"]
        case .green: return ["Green"]
        case .yellow: return ["Yellow"]
        case .blue: return ["Blue"]
        case .num0: return ["Num0"]
        case .num1: return ["Num1"]
        case .num2: return ["Num2"]
        case .num3: return ["Num3"]
        case .num4: return ["Num4"]
        case .num5: return ["Num5"]
        case .num6: return ["Num6"]
        case .num7: return ["Num7"]
        case .num8: return ["Num8"]
        case .num9: return ["Num9"]
        case .display: return ["Display"]
        case .subtitles: return ["SubTitle", "CC"]
        case .audioTrack: return ["Audio"]
        case .guide: return ["GGuide", "EPG", "Guide"]
        case .hdmi1: return ["Hdmi1"]
        case .hdmi2: return ["Hdmi2"]
        case .hdmi3: return ["Hdmi3"]
        case .hdmi4: return ["Hdmi4"]
        }
    }

    /// Built-in code used when the TV did not report one.
    /// Source: official Sony IRCC-IP table (pro-bravia.sony.net), except where noted.
    public var fallbackCode: String {
        switch self {
        case .power: return "AAAAAQAAAAEAAAAVAw=="
        case .powerOff: return "AAAAAQAAAAEAAAAvAw==" // getRemoteControllerInfo example in Sony docs
        case .wakeUp: return "AAAAAQAAAAEAAAAuAw==" // community lists, not in the official table
        case .input: return "AAAAAQAAAAEAAAAlAw=="
        case .home: return "AAAAAQAAAAEAAABgAw=="
        case .back: return "AAAAAgAAAJcAAAAjAw=="
        case .options: return "AAAAAgAAAJcAAAA2Aw=="
        case .up: return "AAAAAQAAAAEAAAB0Aw=="
        case .down: return "AAAAAQAAAAEAAAB1Aw=="
        case .left: return "AAAAAQAAAAEAAAA0Aw=="
        case .right: return "AAAAAQAAAAEAAAAzAw=="
        case .confirm: return "AAAAAQAAAAEAAABlAw=="
        case .volumeUp: return "AAAAAQAAAAEAAAASAw=="
        case .volumeDown: return "AAAAAQAAAAEAAAATAw=="
        case .mute: return "AAAAAQAAAAEAAAAUAw=="
        case .channelUp: return "AAAAAQAAAAEAAAAQAw=="
        case .channelDown: return "AAAAAQAAAAEAAAARAw=="
        case .play: return "AAAAAgAAAJcAAAAaAw=="
        case .pause: return "AAAAAgAAAJcAAAAZAw=="
        case .stop: return "AAAAAgAAAJcAAAAYAw=="
        case .rewind: return "AAAAAgAAAJcAAAAbAw==" // community lists
        case .forward: return "AAAAAgAAAJcAAAAcAw==" // community lists
        case .previous: return "AAAAAgAAAJcAAAA8Aw=="
        case .next: return "AAAAAgAAAJcAAAA9Aw=="
        case .red: return "AAAAAgAAAJcAAAAlAw=="
        case .green: return "AAAAAgAAAJcAAAAmAw=="
        case .yellow: return "AAAAAgAAAJcAAAAnAw=="
        case .blue: return "AAAAAgAAAJcAAAAkAw=="
        case .num1: return "AAAAAQAAAAEAAAAAAw=="
        case .num2: return "AAAAAQAAAAEAAAABAw=="
        case .num3: return "AAAAAQAAAAEAAAACAw=="
        case .num4: return "AAAAAQAAAAEAAAADAw=="
        case .num5: return "AAAAAQAAAAEAAAAEAw=="
        case .num6: return "AAAAAQAAAAEAAAAFAw=="
        case .num7: return "AAAAAQAAAAEAAAAGAw=="
        case .num8: return "AAAAAQAAAAEAAAAHAw=="
        case .num9: return "AAAAAQAAAAEAAAAIAw=="
        case .num0: return "AAAAAQAAAAEAAAAJAw=="
        case .display: return "AAAAAQAAAAEAAAA6Aw=="
        case .subtitles: return "AAAAAgAAAJcAAAAoAw=="
        case .audioTrack: return "AAAAAQAAAAEAAAAXAw=="
        case .guide: return "AAAAAQAAAAEAAAAOAw==" // community lists
        case .hdmi1: return "AAAAAgAAABoAAABaAw=="
        case .hdmi2: return "AAAAAgAAABoAAABbAw=="
        case .hdmi3: return "AAAAAgAAABoAAABcAw=="
        case .hdmi4: return "AAAAAgAAABoAAABdAw=="
        }
    }

    public static func digit(_ value: Int) -> RemoteKey? {
        switch value {
        case 0: return .num0
        case 1: return .num1
        case 2: return .num2
        case 3: return .num3
        case 4: return .num4
        case 5: return .num5
        case 6: return .num6
        case 7: return .num7
        case 8: return .num8
        case 9: return .num9
        default: return nil
        }
    }

    public static func hdmi(port: Int) -> RemoteKey? {
        switch port {
        case 1: return .hdmi1
        case 2: return .hdmi2
        case 3: return .hdmi3
        case 4: return .hdmi4
        default: return nil
        }
    }
}

/// Resolves keys to IRCC codes, preferring the codes reported by the TV itself.
public struct IRCCKeymap: Equatable, Sendable {
    public var tvCodes: [String: String]

    public init(tvCodes: [String: String] = [:]) {
        self.tvCodes = tvCodes
    }

    public func code(for key: RemoteKey) -> String {
        for name in key.tvNames {
            if let code = tvCodes[name], IRCC.isValidCode(code), !code.isEmpty {
                return code
            }
        }
        return key.fallbackCode
    }

    /// Extracts `name → value` pairs from a `getRemoteControllerInfo` result.
    /// The result is heterogeneous: `[{bundled, type}, [{name, value}, ...]]`.
    public static func parse(remoteControllerInfo result: [Any]) -> [String: String] {
        var codes: [String: String] = [:]
        for element in result {
            guard let list = element as? [[String: Any]] else { continue }
            for item in list {
                if let name = item["name"] as? String,
                   let value = item["value"] as? String,
                   !name.isEmpty, IRCC.isValidCode(value), !value.isEmpty {
                    codes[name] = value
                }
            }
        }
        return codes
    }
}

enum IRCC {
    static let soapAction = "\"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC\""

    /// IRCC codes are base64; anything else would be injected into the SOAP XML.
    static func isValidCode(_ code: String) -> Bool {
        code.range(of: "^[A-Za-z0-9+/]*={0,2}$", options: .regularExpression) != nil
    }

    static func envelope(code: String) -> String {
        "<?xml version=\"1.0\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:X_SendIRCC xmlns:u=\"urn:schemas-sony-com:service:IRCC:1\">"
            + "<IRCCCode>\(code)</IRCCCode>"
            + "</u:X_SendIRCC></s:Body></s:Envelope>"
    }
}
