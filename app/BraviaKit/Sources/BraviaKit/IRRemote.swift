import Foundation
import PultIR

/// The TV the IR bridge controls: one command per key, taken from a profile and/or learned
/// from the original remote. Keys are `RemoteKey.rawValue` plus profile-only keys such as `menu`.
public struct IRRemote: Codable, Equatable, Sendable {
    public var name: String
    public var profileID: String?
    public var keys: [String: IRCommand]
    /// Keys whose command was learned rather than taken from the profile.
    public var learnedKeys: Set<String>

    public init(name: String, profileID: String? = nil, keys: [String: IRCommand] = [:], learnedKeys: Set<String> = []) {
        self.name = name
        self.profileID = profileID
        self.keys = keys
        self.learnedKeys = learnedKeys
    }

    /// Remotes built by learning are stored without a name, so "My TV" follows the app language.
    public var displayName: String {
        name.isEmpty ? String(localized: "My TV", bundle: .module, comment: "Name of a TV remote built by learning") : name
    }

    public init(profile: IRProfile) {
        self.init(name: profile.name, profileID: profile.id, keys: profile.keys)
    }

    /// Built-in Sony profile from the IRCC table, preferring codes the TV itself reported.
    public static func sony(keymap: IRCCKeymap = IRCCKeymap()) -> IRRemote {
        var keys: [String: IRCommand] = [:]
        for key in RemoteKey.allCases {
            if let code = SIRCCode(ircc: keymap.code(for: key)) ?? SIRCCode(ircc: key.fallbackCode) {
                keys[key.rawValue] = .code(code.irCode)
            }
        }
        return IRRemote(name: "Sony BRAVIA", profileID: Self.sonyProfileID, keys: keys)
    }

    public static let sonyProfileID = "sony-builtin"

    /// Other buttons that do the same job on remotes without the key itself.
    static let substitutes: [RemoteKey: [String]] = [
        .options: ["menu"],
        .home: ["menu"],
        .back: ["exit"],
        .display: ["info"],
        .powerOff: [],
        .wakeUp: [],
    ]

    public func command(for key: RemoteKey) -> IRCommand? {
        if let command = keys[key.rawValue] { return command }
        for name in Self.substitutes[key] ?? [] {
            if let command = keys[name] { return command }
        }
        return nil
    }

    public mutating func setLearned(_ command: IRCommand, for key: String) {
        keys[key] = command
        learnedKeys.insert(key)
    }
}
