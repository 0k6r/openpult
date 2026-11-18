import Foundation
import OSLog
import Security

/// The app's bundle id keeps Keychain items and logs per build (forks use their own id).
private let appIdentifier = Bundle.main.bundleIdentifier ?? "openpult"
private let logger = Logger(subsystem: appIdentifier, category: "Keychain")

public struct SavedTV: Codable, Equatable, Sendable {
    public var host: String
    public var modelName: String
    public var macAddress: String?
    /// IRCC codes reported by the TV (`getRemoteControllerInfo`), cached.
    public var irccCodes: [String: String]

    public init(host: String, modelName: String, macAddress: String? = nil, irccCodes: [String: String] = [:]) {
        self.host = host
        self.modelName = modelName
        self.macAddress = macAddress
        self.irccCodes = irccCodes
    }
}

/// The IR bridge this iPhone is paired with. The BLE bond itself is kept by iOS.
public struct SavedBlaster: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// How keys reach the TV: Sony IP Control over Wi‑Fi, or the BLE → IR bridge.
public enum ControlMode: String, Codable, Sendable {
    case network, infrared
}

public protocol SecretStore: AnyObject {
    func string(for key: String) -> String?
    func set(_ value: String?, for key: String)
}

/// Generic-password Keychain items for the PSK / PIN / auth cookie.
public final class KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String? = nil) {
        self.service = service ?? appIdentifier
    }

    public func string(for key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                logger.error("Keychain read \(key, privacy: .public) failed: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String?, for key: String) {
        guard let value else {
            let status = SecItemDelete(baseQuery(key) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                logger.error("Keychain delete \(key, privacy: .public) failed: \(status)")
            }
            return
        }
        let data = Data(value.utf8)
        // Update in place so a failed write never leaves the item deleted.
        var status = SecItemUpdate(baseQuery(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = baseQuery(key)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        if status != errSecSuccess {
            logger.error("Keychain write \(key, privacy: .public) failed: \(status)")
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

public final class MemorySecretStore: SecretStore {
    private var values: [String: String] = [:]

    public init() {}

    public func string(for key: String) -> String? { values[key] }
    public func set(_ value: String?, for key: String) { values[key] = value }
}

/// Persists the selected TV (UserDefaults) and its credentials (Keychain).
public final class TVStore {
    private let defaults: UserDefaults
    private let secrets: SecretStore

    private enum Key {
        static let savedTV = "savedTV"
        static let clientID = "clientID"
        static let credentials = "credentials"
        static let savedBlaster = "savedBlaster"
        static let irRemote = "irRemote"
        static let controlMode = "controlMode"
    }

    public init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public var savedTV: SavedTV? {
        get {
            guard let data = defaults.data(forKey: Key.savedTV) else { return nil }
            return try? JSONDecoder().decode(SavedTV.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.savedTV)
            } else {
                defaults.removeObject(forKey: Key.savedTV)
            }
        }
    }

    public var credentials: Credentials {
        get {
            guard let json = secrets.string(for: Key.credentials),
                  let value = try? JSONDecoder().decode(Credentials.self, from: Data(json.utf8))
            else { return .none }
            return value
        }
        set {
            if newValue == .none {
                secrets.set(nil, for: Key.credentials)
            } else if let data = try? JSONEncoder().encode(newValue) {
                secrets.set(String(decoding: data, as: UTF8.self), for: Key.credentials)
            }
        }
    }

    public var savedBlaster: SavedBlaster? {
        get {
            guard let data = defaults.data(forKey: Key.savedBlaster) else { return nil }
            return try? JSONDecoder().decode(SavedBlaster.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.savedBlaster)
            } else {
                defaults.removeObject(forKey: Key.savedBlaster)
            }
        }
    }

    /// The TV remote the IR bridge plays (profile + learned keys).
    public var irRemote: IRRemote? {
        get {
            guard let data = defaults.data(forKey: Key.irRemote) else { return nil }
            return try? JSONDecoder().decode(IRRemote.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.irRemote)
            } else {
                defaults.removeObject(forKey: Key.irRemote)
            }
        }
    }

    public var controlMode: ControlMode {
        get { defaults.string(forKey: Key.controlMode).flatMap(ControlMode.init(rawValue:)) ?? .network }
        set { defaults.set(newValue.rawValue, forKey: Key.controlMode) }
    }

    /// Stable id the TV uses to remember this phone after PIN pairing.
    public var clientID: String {
        if let existing = defaults.string(forKey: Key.clientID), !existing.isEmpty {
            return existing
        }
        let created = "Pult:\(UUID().uuidString)"
        defaults.set(created, forKey: Key.clientID)
        return created
    }

    public func forgetTV() {
        savedTV = nil
        credentials = .none
    }
}
