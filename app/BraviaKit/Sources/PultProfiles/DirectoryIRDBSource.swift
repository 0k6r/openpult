import Foundation

/// A Flipper-IRDB checkout on disk (TVs/, LICENSE, README.md): fixtures, a full clone in tests, developer tools.
///
/// Like the Python importer's os.walk it only reads files, never follows symlinks, skips folders it cannot list and
/// lists symlinks, special files and entries it cannot stat with a loader that throws
/// `IRDBFileError.notRegularFile`; unreadable files throw `IRDBFileError.unreadable` with Python's error name.
public struct DirectoryIRDBSource: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The files under root/TVs, paths relative to TVs/. Throws if TVs/ is missing, a symlink or unreadable.
    public func files() throws -> [IRDBFile] {
        let tvs = root.appendingPathComponent("TVs", isDirectory: true)
        guard Self.kind(of: tvs.path) == .directory else { throw ProfileImportError.missingTVsFolder(tvs.path) }
        _ = try FileManager.default.contentsOfDirectory(atPath: tvs.path)
        var out: [IRDBFile] = []
        Self.list(tvs, rel: [], into: &out)
        return out
    }

    /// root/LICENSE, nil unless it is a regular file of at most 16 KiB.
    public func license() -> Data? {
        Self.readRegular(root.appendingPathComponent("LICENSE"), limit: ImportLimits.maxLicenseBytes)
    }

    /// `ProfileImporter.licenseNote(readme:)` of root/README.md.
    public func licenseNote() -> String? {
        Self.readRegular(root.appendingPathComponent("README.md"), limit: ImportLimits.maxFileBytes)
            .flatMap(ProfileImporter.licenseNote(readme:))
    }

    // MARK: Private

    private enum Kind { case directory, regular, symlinkToDirectory, other }

    private static func kind(of path: String) -> Kind {
        guard let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType else {
            return .other   // os.walk puts entries it cannot stat among the files; the importer skips them
        }
        switch type {
        case .typeDirectory:
            return .directory
        case .typeRegular:
            return .regular
        case .typeSymbolicLink:
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? .symlinkToDirectory : .other
        default:
            return .other
        }
    }

    /// Mirrors `os.walk(followlinks=False)` as far as the importer can tell: symlinked folders are dropped, a folder at
    /// the depth limit is not entered (one entry stands for its contents, so the importer reports it).
    private static func list(_ dir: URL, rel: [String], into out: inout [IRDBFile]) {
        // os.walk(onerror=None) skips folders it cannot list.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(by: Py.less) else {
            return
        }
        if rel.count >= ImportLimits.maxDepth {
            if let first = names.first {
                out.append(IRDBFile(path: (rel + [first]).joined(separator: "/")) {
                    throw IRDBFileError.notRegularFile
                })
            }
            return
        }
        for name in names {
            let url = dir.appendingPathComponent(name)
            let path = (rel + [name]).joined(separator: "/")
            switch kind(of: url.path) {
            case .directory:
                if !Py.starts(name, with: ".") {
                    list(url, rel: rel + [name], into: &out)
                }
            case .symlinkToDirectory:
                continue
            case .regular:
                out.append(IRDBFile(path: path) {
                    guard kind(of: url.path) == .regular else { throw IRDBFileError.notRegularFile }
                    do {
                        return try readPrefix(url, count: ImportLimits.maxFileBytes + 1)
                    } catch {
                        throw IRDBFileError.unreadable(pythonErrorName(error))
                    }
                })
            case .other:
                out.append(IRDBFile(path: path) { throw IRDBFileError.notRegularFile })
            }
        }
    }

    /// The Python exception class `open()` would raise for this error.
    static func pythonErrorName(_ error: Error) -> String {
        var error = error as NSError
        if error.domain == NSCocoaErrorDomain, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            error = underlying
        }
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case EACCES, EPERM: return "PermissionError"
            case ENOENT: return "FileNotFoundError"
            case EISDIR: return "IsADirectoryError"
            default: return "OSError"
            }
        }
        switch error.code {
        case NSFileReadNoPermissionError: return "PermissionError"
        case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return "FileNotFoundError"
        default: return "OSError"
        }
    }

    /// At most `count` bytes from the start of the file.
    private static func readPrefix(_ url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func readRegular(_ url: URL, limit: Int) -> Data? {
        guard kind(of: url.path) == .regular, let data = try? readPrefix(url, count: limit + 1), data.count <= limit
        else { return nil }
        return data
    }
}
