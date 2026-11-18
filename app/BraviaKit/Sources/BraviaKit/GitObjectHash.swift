import CryptoKit
import Foundation

/// Git object ids (SHA-1 of "<type> <length>\0" + content), used to verify files downloaded from GitHub.
public enum GitObjectHash {
    /// One entry of a git tree object.
    public struct TreeEntry: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case blob(executable: Bool)
            case symlink
            case tree
            case submodule

            /// The mode as git writes it inside tree objects (no leading zero for trees).
            var mode: String {
                switch self {
                case .blob(let executable): return executable ? "100755" : "100644"
                case .symlink: return "120000"
                case .tree: return "40000"
                case .submodule: return "160000"
                }
            }
        }

        public let name: String
        public let kind: Kind
        /// 40 lowercase hex characters.
        public let sha: String

        public init(name: String, kind: Kind, sha: String) {
            self.name = name
            self.kind = kind
            self.sha = sha
        }
    }

    public enum HashError: Error, Equatable {
        case invalidSHA(String)
        case invalidName(String)
        case duplicateName(String)
    }

    /// The id git gives a file with this content (`git hash-object`).
    public static func blob(_ data: Data) -> String {
        object(type: "blob", content: data)
    }

    /// The id of a tree with these entries (`git mktree`); the entries may come in any order.
    public static func tree(_ entries: [TreeEntry]) throws -> String {
        var seen = Set<[UInt8]>()
        var keyed: [(key: [UInt8], entry: TreeEntry, raw: [UInt8])] = []
        keyed.reserveCapacity(entries.count)
        for entry in entries {
            let name = Array(entry.name.utf8)
            guard !name.isEmpty, !name.contains(0), !name.contains(UInt8(ascii: "/")),
                  entry.name != ".", entry.name != ".." else {
                throw HashError.invalidName(entry.name)
            }
            guard seen.insert(name).inserted else { throw HashError.duplicateName(entry.name) }
            guard let raw = rawSHA(entry.sha) else { throw HashError.invalidSHA(entry.sha) }
            // Git compares names as bytes, with a "/" appended to the names of trees.
            let key = entry.kind == .tree ? name + [UInt8(ascii: "/")] : name
            keyed.append((key, entry, raw))
        }
        keyed.sort { $0.key.lexicographicallyPrecedes($1.key) }
        var content = Data()
        for item in keyed {
            content.append(contentsOf: Array(item.entry.kind.mode.utf8))
            content.append(UInt8(ascii: " "))
            content.append(contentsOf: Array(item.entry.name.utf8))
            content.append(0)
            content.append(contentsOf: item.raw)
        }
        return object(type: "tree", content: content)
    }

    /// `true` for 40 lowercase hex characters.
    public static func isSHA(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 40 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func object(type: String, content: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("\(type) \(content.count)\0".utf8))
        hasher.update(data: content)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func rawSHA(_ hex: String) -> [UInt8]? {
        guard isSHA(hex) else { return nil }
        let digits = Array(hex.utf8).map { $0 <= 0x39 ? $0 - 0x30 : $0 - 0x61 + 10 }
        return stride(from: 0, to: 40, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
    }
}
