import Foundation

/// How the app authenticates with the TV.
public enum Credentials: Codable, Equatable, Sendable {
    case none
    /// Pre-Shared Key, sent as `X-Auth-PSK`.
    case psk(String)
    /// PIN pairing: the PIN is kept to renew the `auth` cookie without showing a new PIN.
    case pin(pin: String, cookie: String?, issuedAt: Date?)

    public var isConfigured: Bool {
        switch self {
        case .none: return false
        case .psk(let key): return !key.isEmpty
        case .pin(_, let cookie, _): return cookie?.isEmpty == false
        }
    }
}

public struct InterfaceInfo: Equatable, Sendable {
    public var productCategory: String
    public var productName: String
    public var modelName: String
    public var interfaceVersion: String

    public var displayName: String {
        if !modelName.isEmpty { return modelName }
        if !productName.isEmpty { return productName }
        return "Sony BRAVIA"
    }
}

public enum PowerStatus: Equatable, Sendable {
    case active
    case standby
    case other(String)
}

public struct SystemInfo: Equatable, Sendable {
    public var model: String
    public var name: String
    public var macAddress: String?
}

public struct TVApp: Identifiable, Hashable, Sendable {
    public var title: String
    public var uri: String
    public var iconURL: URL?
    public var id: String { uri }

    public init(title: String, uri: String, iconURL: URL?) {
        self.title = title
        self.uri = uri
        self.iconURL = iconURL
    }
}

public struct ExternalInput: Identifiable, Hashable, Sendable {
    public var uri: String
    public var title: String
    public var label: String
    public var isConnected: Bool
    public var id: String { uri }

    public init(uri: String, title: String, label: String, isConnected: Bool) {
        self.uri = uri
        self.title = title
        self.label = label
        self.isConnected = isConnected
    }

    public var displayName: String {
        label.isEmpty ? title : "\(title) — \(label)"
    }

    /// HDMI port number parsed from `extInput:hdmi?port=N`, if any.
    public var hdmiPort: Int? {
        guard uri.hasPrefix("extInput:hdmi"),
              let components = URLComponents(string: uri),
              let value = components.queryItems?.first(where: { $0.name == "port" })?.value
        else { return nil }
        return Int(value)
    }
}

public struct DiscoveredTV: Identifiable, Hashable, Sendable {
    public var host: String
    public var modelName: String
    public var id: String { host }

    public init(host: String, modelName: String) {
        self.host = host
        self.modelName = modelName
    }
}
