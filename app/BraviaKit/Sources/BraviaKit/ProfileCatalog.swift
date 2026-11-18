import Foundation
import PultIR

public struct IRBrand: Identifiable, Hashable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let file: String
    public let profiles: Int
}

public struct IRNamedCommand: Equatable, Sendable {
    public let name: String
    public let command: IRCommand
}

public struct IRProfile: Identifiable, Equatable, Sendable {
    public let id: String
    public let brand: String
    public let name: String
    public let models: [String]
    public let weight: Int
    public let keys: [String: IRCommand]
    public let extra: [IRNamedCommand]
}

public struct PowerScanEntry: Equatable, Sendable {
    public let command: IRCommand
    public let brands: [String]
    public let weight: Int
}

/// TV code profiles in a folder (see profiles/SCHEMA.md), built on the device by `ProfileDatabase`.
@MainActor
public final class ProfileCatalog {
    public enum CatalogError: Error, Equatable {
        case unsupportedSchema(Int)
        /// index.json names a brand file outside `brands/`.
        case invalidFile(String)
    }

    /// Where the profiles come from (`source` in index.json).
    public struct Source: Equatable, Sendable, Decodable {
        public let db: String?
        public let url: String?
        public let commit: String?
        public let license: String?
        /// A license remark, e.g. that early upstream commits are not covered by CC0.
        public let note: String?
    }

    public let directory: URL
    private var indexCache: Index?
    private var profileCache: [String: [IRProfile]] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    public func brands() throws -> [IRBrand] {
        try index().brands
    }

    public func source() throws -> Source? {
        try index().source
    }

    private func index() throws -> Index {
        if let indexCache { return indexCache }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: directory.appendingPathComponent("index.json")))
        guard index.schema == 1 else { throw CatalogError.unsupportedSchema(index.schema) }
        indexCache = index
        return index
    }

    public func brand(named name: String) throws -> IRBrand? {
        try brands().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Profiles of a brand, most likely first.
    public func profiles(for brand: IRBrand) throws -> [IRProfile] {
        if let cached = profileCache[brand.id] { return cached }
        guard Self.isBrandFile(brand.file) else { throw CatalogError.invalidFile(brand.file) }
        let raw = try JSONDecoder().decode([RawProfile].self, from: Data(contentsOf: directory.appendingPathComponent(brand.file)))
        let profiles = raw.map(\.profile)
        profileCache[brand.id] = profiles
        return profiles
    }

    /// Unique power codes across all brands, most common first.
    public func powerScan() throws -> [PowerScanEntry] {
        let raw = try JSONDecoder().decode([RawPowerEntry].self, from: Data(contentsOf: directory.appendingPathComponent("power_scan.json")))
        return raw.compactMap { entry in
            entry.cmd.command.map { PowerScanEntry(command: $0, brands: entry.brands, weight: entry.weight) }
        }
    }

    /// The most likely profile of the given brands whose power key is `command`.
    public func bestProfile(withPower command: IRCommand, brands names: [String]) throws -> IRProfile? {
        var best: IRProfile?
        for name in names {
            guard let brand = try brand(named: name) else { continue }
            // power_scan lists `power`, or `wakeUp` for remotes without a toggle.
            for profile in try profiles(for: brand)
            where (profile.keys[RemoteKey.power.rawValue] ?? profile.keys[RemoteKey.wakeUp.rawValue]) == command {
                if best == nil || profile.weight > best!.weight || (profile.weight == best!.weight && profile.keys.count > best!.keys.count) {
                    best = profile
                }
            }
        }
        return best
    }

    /// "brands/<name>.json" with a plain ASCII name: index.json cannot point outside the folder.
    static func isBrandFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "brands", let name = parts.last, name.hasSuffix(".json"),
              name.first != "." else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
        }
    }

    // MARK: - JSON

    private struct Index: Decodable {
        let schema: Int
        let source: Source?
        let brands: [IRBrand]

        private enum CodingKeys: String, CodingKey { case schema, source, brands }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try container.decode(Int.self, forKey: .schema)
            // Informational only: a malformed source must not hide the profiles.
            source = try? container.decodeIfPresent(Source.self, forKey: .source)
            brands = schema == 1 ? try container.decode([IRBrand].self, forKey: .brands) : []
        }
    }

    private struct RawPowerEntry: Decodable {
        let cmd: CompactCommand
        let brands: [String]
        let weight: Int
    }

    private struct RawProfile: Decodable {
        let id: String
        let brand: String
        let name: String
        let models: [String]?
        let weight: Int?
        let keys: [String: CompactCommand]
        let extra: [RawExtra]?

        struct RawExtra: Decodable {
            let name: String
            let cmd: CompactCommand
        }

        var profile: IRProfile {
            IRProfile(
                id: id,
                brand: brand,
                name: name,
                models: models ?? [],
                weight: weight ?? 1,
                keys: keys.compactMapValues(\.command),
                extra: (extra ?? []).compactMap { item in item.cmd.command.map { IRNamedCommand(name: item.name, command: $0) } }
            )
        }
    }

    /// `{"p": "NEC", "a": 4, "c": 8}` or `{"raw": {"f": 38000, "d": 33, "i": [...], "r": [...]}}`.
    struct CompactCommand: Decodable {
        let p: String?
        let a: UInt32?
        let c: UInt32?
        let raw: Raw?

        struct Raw: Decodable {
            let f: Int
            let d: Int?
            let i: [Int]?
            let r: [Int]
        }

        /// Unknown protocols are skipped (an older app reading newer profiles).
        var command: IRCommand? {
            if let raw {
                // The importer collapses identical recorded frames into one repeat section; most receivers
                // want at least two frames (Sony three), so a repeat-only recording is played twice.
                let intro = raw.i ?? []
                return .raw(IRSignal(carrierHz: raw.f, dutyPercent: raw.d ?? 33, intro: intro, repeat: raw.r, minRepeats: intro.isEmpty ? 2 : 1))
            }
            guard let p, let proto = IRProtocolID(rawValue: p), let a, let c else { return nil }
            return .code(IRCode(proto: proto, address: a, command: c))
        }
    }
}
