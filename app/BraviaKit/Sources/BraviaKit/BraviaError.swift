import Foundation

public enum BraviaError: Error, Equatable, Sendable {
    /// Timeout, connection refused, host down.
    case unreachable
    /// iOS blocked local network access (or Wi‑Fi is off).
    case localNetworkDenied
    /// HTTP 401/403 or JSON-RPC error 401/403.
    case unauthorized
    /// The PIN entered during pairing was rejected or has expired.
    case wrongPIN
    /// The TV refused to start PIN pairing (IP control / remote access disabled).
    case pairingRejected
    /// JSON-RPC 40005 or the legacy "not power-on" message.
    case displayOff
    /// `setTextForm` called while no text field is focused on the TV.
    case keyboardInactive
    /// Method, version or endpoint not supported by this TV.
    case unsupported
    /// The TV did not accept an IRCC key code.
    case keyRejected
    case invalidResponse
    case invalidInput(String)
    case tv(code: Int, message: String)

    static func from(urlError: URLError) -> BraviaError {
        switch urlError.code {
        case .notConnectedToInternet:
            // iOS reports a denied "Local Network" permission as -1009 as well.
            return .localNetworkDenied
        case .appTransportSecurityRequiresSecureConnection:
            // ATS only allows plain HTTP to IP addresses and .local names.
            return .invalidInput(L10n.enterTVAddress)
        default:
            return .unreachable
        }
    }

    static func from(code: Int, message: String) -> BraviaError {
        switch code {
        case 401, 403:
            return .unauthorized
        case 40005:
            return .displayOff
        case 12, 14, 15, 404, 501:
            return .unsupported
        default:
            if message.lowercased().contains("not power-on") {
                return .displayOff
            }
            return .tv(code: code, message: message)
        }
    }
}

extension BraviaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreachable:
            return String(
                localized: "The TV isn't responding. Make sure it's on and connected to the same Wi‑Fi network as your iPhone.",
                bundle: .module, comment: "Error: the TV does not answer over the network."
            )
        case .localNetworkDenied:
            return String(
                localized: "No access to the local network. Turn on Wi‑Fi and allow OpenPult access in Settings → Privacy & Security → Local Network.",
                bundle: .module, comment: "Error: iOS denied the Local Network permission. OpenPult is the app name."
            )
        case .unauthorized:
            return String(
                localized: "The TV rejected the command. Connect to it again.",
                bundle: .module, comment: "Error: HTTP 401/403 from the TV; the banner offers a Connect button."
            )
        case .wrongPIN:
            return String(
                localized: "The PIN is wrong or has expired. Request a new PIN and enter it within a minute.",
                bundle: .module, comment: "Error: the TV rejected the pairing PIN."
            )
        case .pairingRejected:
            return String(
                localized: "The TV doesn't allow PIN pairing. Turn on IP Control and Remote Device/Renderer on the TV, or use a Pre-Shared Key.",
                bundle: .module, comment: "Error: the TV refused to start PIN pairing. IP Control and Remote Device/Renderer are Sony menu items."
            )
        case .displayOff:
            return String(localized: "The TV screen is off.", bundle: .module, comment: "Error: JSON-RPC 40005, display is off.")
        case .keyboardInactive:
            return String(
                localized: "No text field is open on the TV. Open search or a text field and try again.",
                bundle: .module, comment: "Error: text was sent while no text field is focused on the TV."
            )
        case .unsupported:
            return String(localized: "Your TV doesn't support this feature.", bundle: .module, comment: "Error: method not supported by the TV.")
        case .keyRejected:
            return String(localized: "The TV didn't accept the button command.", bundle: .module, comment: "Error: the TV rejected an IRCC key code.")
        case .invalidResponse:
            return String(localized: "The TV sent an unexpected response.", bundle: .module, comment: "Error: the TV's response could not be parsed.")
        case .invalidInput(let message):
            return message
        case .tv(let code, let message):
            return message.isEmpty
                ? String(localized: "TV error (\(code)).", bundle: .module, comment: "Error from the TV without a message. %lld is the error code.")
                : String(localized: "TV error (\(code)): \(message).", bundle: .module, comment: "Error from the TV. %lld is the error code, %@ the TV's message (usually English).")
        }
    }
}
