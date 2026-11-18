import Foundation

/// A file of the database's TVs/ folder.
public struct IRDBFile: Sendable {
    /// Path relative to TVs/ (without "TVs/"), "/"-separated, e.g. "Acme/Acme_AB-1000.ir".
    public let path: String
    /// Reads the file; called at most once, during `ProfileImporter.run`.
    ///
    /// Throw `IRDBFileError` to have the file skipped and counted like the Python importer does; any other error
    /// stops the import and is rethrown by `run` (a damaged download must not silently drop codes).
    public let load: @Sendable () throws -> Data

    public init(path: String, load: @escaping @Sendable () throws -> Data) {
        self.path = path
        self.load = load
    }

    public init(path: String, data: Data) {
        self.init(path: path) { data }
    }
}

/// Files the importer skips and counts instead of failing.
public enum IRDBFileError: Error, Equatable, Sendable {
    /// A symlink, FIFO, device or socket: "file: symlink or special file", not counted as seen.
    case notRegularFile
    /// A file that exists but cannot be read: "file: unreadable (<kind>)", kind as in Python, e.g. "PermissionError".
    case unreadable(String)
}

/// Where the files come from; stored in index.json.
public struct ImportSource: Sendable, Equatable {
    /// The 40-character commit SHA of the database.
    public let commit: String
    /// The repository URL, a plain https URL.
    public let url: String
    /// The license remark stored as `source.note`; cleaned and capped at 300 characters, nil or empty for none.
    ///
    /// Pass `ProfileImporter.licenseNote(readme:)` of the database's README.md to match the Python importer, which
    /// reads the README itself when no note is given (here nil means no note).
    public let licenseNote: String?

    public init(commit: String, url: String = ProfileImporter.defaultURL, licenseNote: String? = nil) {
        self.commit = commit
        self.url = url
        self.licenseNote = licenseNote
    }
}

/// The generated files: index.json, brands/<id>.json and power_scan.json (profiles/SCHEMA.md).
public struct ProfileBundle: Sendable {
    /// Paths relative to the profiles folder, brand files first (sorted), then index.json and power_scan.json.
    public let files: [(path: String, data: Data)]
    public let report: ImportReport

    /// Writes the files into `directory` (created if needed), meant for a new, empty folder: files are replaced one
    /// by one and stale brand files of an earlier import are not removed, unlike the Python importer's --out.
    public func write(to directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory.appendingPathComponent("brands", isDirectory: true),
                                    withIntermediateDirectories: true)
        for file in files {
            try file.data.write(to: directory.appendingPathComponent(file.path), options: .atomic)
        }
    }
}

/// Counters of an import, the same as the report of the Python importer.
public struct ImportReport: Sendable, Equatable {
    public struct NameStat: Sendable, Equatable {
        /// Normalized button name.
        public let name: String
        /// Number of files with a button of this name.
        public let files: Int
        /// The first button name seen with this normalization.
        public let example: String
        /// The key it maps to ("power", "letter:red", "extra (reviewed)" or "extra (UNREVIEWED)").
        public let target: String
    }

    public struct BrandCount: Sendable, Equatable {
        public let name: String
        public let profiles: Int
    }

    public let commit: String
    public let filesSeen: Int
    public let filesUsed: Int
    public let brands: Int
    public let profiles: Int
    /// "parsed" / "raw" -> buttons accepted from files.
    public let buttonsIn: [String: Int]
    /// "parsed" / "raw" -> commands in the generated profiles.
    public let codesOut: [String: Int]
    public let duplicatesDropped: Int
    /// Reason -> count; the reasons are the same strings as in the Python report.
    public let skippedFiles: [String: Int]
    public let skippedCodes: [String: Int]
    public let recovered: [String: Int]
    /// Reason -> up to three places where it happened.
    public let skipExamples: [String: [String]]
    /// Protocol ("raw" for raw recordings) -> commands in the generated profiles.
    public let protocols: [String: Int]
    public let powerScanCodes: Int
    /// The 20 brands with the most profiles.
    public let topBrands: [BrandCount]
    /// Total size of the generated files (the Python report also counts LICENSE and other files in --out).
    public let sizeBytes: Int
    // The Python report's dicts are ordered (protocols by count, ties first seen); these dictionaries are not.
    /// Every normalized button name, most frequent first.
    public let nameStats: [NameStat]

    /// All commands in the generated profiles.
    public var codes: Int { codesOut.values.reduce(0, +) }
}

public enum ProfileImportError: Error, Equatable, Sendable {
    /// The commit is not a 40-character lowercase hex SHA.
    case invalidCommit(String)
    /// The URL is not a plain https URL.
    case invalidURL(String)
    /// Two files share a path.
    case duplicatePath(String)
    /// The database folder has no TVs/ directory (or it is a symlink).
    case missingTVsFolder(String)
    /// key_aliases.json is malformed.
    case invalidAliases(String)
}

/// Input hygiene limits (import_flipper_irdb.py, "Input hygiene").
enum ImportLimits {
    static let maxFileBytes = 1 << 20
    static let maxLicenseBytes = 16 << 10
    static let maxPathChars = 200
    static let maxDepth = 8
    static let maxButtonsPerFile = 256
    static let maxRawDurations = 4096
    static let maxNoteChars = 300
}

/// Builds TV profiles from Flipper-IRDB .ir files: a Swift port of tools/profiles/import_flipper_irdb.py whose
/// output is byte-identical to the Python importer for the same input (checked by tests), as long as the names in
/// the files only use characters that both Unicode versions know (see `Py`).
public enum ProfileImporter {
    /// Bump when the generated files change for the same input, so stored databases are rebuilt
    /// (ProfileImporterGoldenTests pins a digest of the fixture output to catch a forgotten bump).
    public static let version = 1
    public static let schemaVersion = 1
    public static let defaultURL = "https://github.com/Lucaslhm/Flipper-IRDB"
    public static let databaseName = "Flipper-IRDB"
    public static let licenseID = "CC0-1.0"
    static let contribPrefix = "contrib/"

    /// Identifies what the generated files depend on besides the input: the importer version and the aliases.
    /// A stored database built with another fingerprint should be rebuilt.
    public static func fingerprint(aliases: KeyAliases) -> String {
        "importer-\(version)-aliases-\(aliases.digest)"
    }

    /// Imports `files` (the TVs/ folder) and `contrib` (openpult additions, sources prefixed with "contrib/").
    ///
    /// The files may come in any order: they are processed in the Python importer's os.walk order, which decides
    /// the display name of brands whose folders differ only in case or punctuation. Hidden files and folders are
    /// ignored; folders nested 8 deep, unsafe paths (control characters, over 200 characters, empty components)
    /// and malformed files and codes are skipped and counted in the report.
    ///
    /// The database LICENSE is not checked here: call `checkLicense(_:)` first. The import runs synchronously on
    /// the calling thread; when called from a task it stops with `CancellationError` once the task is cancelled.
    ///
    /// Throws `ProfileImportError` for invalid arguments or two files with the same path, and rethrows any error of
    /// a loader that is not an `IRDBFileError`.
    public static func run(files: [IRDBFile], contrib: [IRDBFile] = [], aliases: KeyAliases,
                           source: ImportSource) throws -> ProfileBundle {
        guard isCommit(source.commit) else { throw ProfileImportError.invalidCommit(source.commit) }
        guard isPlainHTTPSURL(source.url) else { throw ProfileImportError.invalidURL(source.url) }
        let note = source.licenseNote.map { ProfileNames.cleanText($0, limit: ImportLimits.maxNoteChars) } ?? ""

        var stats = ImportStats()
        var brands: [String: BrandEntry] = [:]
        for (prefix, list) in [("", files), (contribPrefix, contrib)] {
            for event in try walkOrder(list) {
                try Task.checkCancellation()
                switch event {
                case .tooDeep(let rel):
                    stats.skip("file: folder nested too deep", Py.prefix(Py.ascii(rel), 80))
                case .unsafe(let rel):
                    stats.skip("file: unsafe file name", Py.prefix(Py.ascii(rel), 80))
                case .file(let rel, let file):
                    try read(file, rel: rel, source: "\(prefix)TVs/\(rel)", aliases: aliases, brands: &brands,
                         stats: &stats)
                }
            }
        }

        var outputs: [(path: String, data: Data)] = []
        var indexBrands: [IndexBrand] = []
        var allProfiles: [Profile] = []
        for brandID in brands.keys.sorted(by: Py.less) {
            let entry = brands[brandID]!
            // Folders that differ only in case/punctuation share an id; the name of the first one wins.
            let profiles = ProfileBuilder.buildProfiles(brandID: brandID, brand: entry.name, files: entry.files,
                                                        keyOrder: aliases.keyOrder)
            let file = "brands/\(brandID).json"
            outputs.append((file, Data(ProfileWriter.formatProfiles(profiles).utf8)))
            indexBrands.append(IndexBrand(id: brandID, name: entry.name, file: file, profiles: profiles.count))
            allProfiles += profiles
        }
        var sourceFields = [("db", databaseName), ("url", source.url), ("commit", source.commit),
                            ("license", licenseID)]
        if !note.isEmpty {
            sourceFields.append(("note", note))
        }
        let index = ProfileWriter.formatIndex(schema: schemaVersion, source: sourceFields, brands: indexBrands)
        outputs.append(("index.json", Data(index.utf8)))
        let power = ProfileBuilder.buildPowerScan(allProfiles)
        outputs.append(("power_scan.json", Data(ProfileWriter.formatPowerScan(power).utf8)))

        let report = makeReport(commit: source.commit, stats: stats, brands: brands.count, profiles: allProfiles,
                                indexBrands: indexBrands, power: power, outputs: outputs, aliases: aliases)
        return ProfileBundle(files: outputs, report: report)
    }

    private static func read(_ file: IRDBFile, rel: String, source: String, aliases: KeyAliases,
                             brands: inout [String: BrandEntry], stats: inout ImportStats) throws {
        let data: Data
        do {
            data = try file.load()
        } catch IRDBFileError.notRegularFile {
            stats.skip("file: symlink or special file", rel)
            return
        } catch IRDBFileError.unreadable(let kind) {
            stats.filesSeen += 1
            stats.skip("file: unreadable (\(kind))", source)
            return
        }
        stats.filesSeen += 1
        if data.count > ImportLimits.maxFileBytes {
            stats.skip("file: larger than 1 MiB", source)
            return
        }
        ProfileBuilder.collect(text: Py.decodeUTF8(data), rel: rel, source: source, aliases: aliases,
                               brands: &brands, stats: &stats)
    }

    private static func makeReport(commit: String, stats: ImportStats, brands: Int, profiles: [Profile],
                                   indexBrands: [IndexBrand], power: [PowerScanCode],
                                   outputs: [(path: String, data: Data)], aliases: KeyAliases) -> ImportReport {
        var codesOut: [String: Int] = [:]
        var protocols: [String: Int] = [:]
        for p in profiles {
            for cmd in p.keys.map(\.cmd) + p.extra.map(\.cmd) {
                codesOut[cmd.isRaw ? "raw" : "parsed", default: 0] += 1
                protocols[cmd.protocolName, default: 0] += 1
            }
        }
        let top = indexBrands.sorted { a, b in
            a.profiles != b.profiles ? a.profiles > b.profiles : Py.less(a.id, b.id)
        }.prefix(20).map { ImportReport.BrandCount(name: $0.name, profiles: $0.profiles) }
        let names = stats.names.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
            .map { name, files in
                ImportReport.NameStat(name: name.value, files: files, example: stats.nameExamples[name] ?? name.value,
                                      target: aliases.describe(name.value))
            }
        return ImportReport(
            commit: commit,
            filesSeen: stats.filesSeen,
            filesUsed: stats.filesUsed,
            brands: brands,
            profiles: profiles.count,
            buttonsIn: stats.buttonsIn,
            codesOut: codesOut,
            duplicatesDropped: stats.duplicatesDropped,
            skippedFiles: stats.skippedFiles,
            skippedCodes: stats.skippedCodes,
            recovered: stats.recovered,
            skipExamples: stats.examples,
            protocols: protocols,
            powerScanCodes: power.count,
            topBrands: Array(top),
            sizeBytes: outputs.reduce(0) { $0 + $1.data.count },
            nameStats: names
        )
    }

    // MARK: Walk order

    enum WalkEvent {
        case file(rel: String, IRDBFile)
        case unsafe(rel: String)
        case tooDeep(rel: String)
    }

    private final class Folder {
        var files: [(name: String, file: IRDBFile)] = []
        var folders: [PyKey: Folder] = [:]
        var tooDeep = false
    }

    /// The files in the order of the Python importer's `os.walk`: in every folder its files sorted by name, then its
    /// subfolders sorted by name. Hidden files and folders are left out, folders at depth `maxDepth` are reported
    /// instead of entered and unsafe paths are reported instead of read.
    static func walkOrder(_ files: [IRDBFile]) throws -> [WalkEvent] {
        let root = Folder()
        var unsafePaths: [String] = []
        var paths = Set<PyKey>()
        for file in files {
            guard paths.insert(PyKey(file.path)).inserted else { throw ProfileImportError.duplicatePath(file.path) }
            let components = Py.split(file.path, separator: "/")
            if components.contains(where: \.isEmpty) {
                unsafePaths.append(file.path)   // "", "/x", "a//b" or "a/": no file system produces these
                continue
            }
            var folder = root
            var depth = 0
            for name in components.dropLast() {
                if depth == ImportLimits.maxDepth {
                    break
                }
                let key = PyKey(name)
                let next = folder.folders[key] ?? Folder()
                folder.folders[key] = next
                folder = next
                depth += 1
            }
            if depth == ImportLimits.maxDepth {
                folder.tooDeep = true
            } else {
                folder.files.append((components[components.count - 1], file))
            }
        }

        var events = unsafePaths.sorted(by: Py.less).map { WalkEvent.unsafe(rel: $0) }
        func visit(_ folder: Folder, rel: String) {
            if folder.tooDeep {
                events.append(.tooDeep(rel: rel))
                return
            }
            for (name, file) in folder.files.sorted(by: { Py.less($0.name, $1.name) }) {
                if Py.starts(name, with: ".") {
                    continue
                }
                let path = rel.isEmpty ? name : "\(rel)/\(name)"
                events.append(ProfileNames.isSafePath(path) ? .file(rel: path, file) : .unsafe(rel: path))
            }
            for (name, child) in folder.folders.sorted(by: { $0.key < $1.key }) where !Py.starts(name.value, with: ".") {
                visit(child, rel: rel.isEmpty ? name.value : "\(rel)/\(name.value)")
            }
        }
        visit(root, rel: "")
        return events
    }

    // MARK: Arguments and license

    static func isCommit(_ text: String) -> Bool {
        let a = Py.scalars(text)
        return a.count == 40 && a.allSatisfy(Py.isLowerHex)
    }

    /// URL_RE = https://[A-Za-z0-9.-]+(/[A-Za-z0-9._-]+)* with `re.fullmatch`.
    static func isPlainHTTPSURL(_ text: String) -> Bool {
        let a = Py.scalars(text)
        let scheme = Array("https://".unicodeScalars)
        guard a.starts(with: scheme) else { return false }
        let pieces = Py.split(Py.string(a[scheme.count...]), separator: "/")
        func allowed(_ piece: String, _ extra: String) -> Bool {
            !piece.isEmpty && piece.unicodeScalars.allSatisfy { Py.isASCIIAlnum($0) || extra.unicodeScalars.contains($0) }
        }
        return allowed(pieces[0], ".-") && pieces.dropFirst().allSatisfy { allowed($0, "._-") }
    }

    /// `check_license` on the database's LICENSE file: the CC0 legal code starts with these two lines; anything
    /// else needs a human review first. Files over 16 KiB are refused.
    public static func checkLicense(_ data: Data) -> Bool {
        guard data.count <= ImportLimits.maxLicenseBytes else { return false }
        let lines = Py.splitLines(Py.decodeUTF8(data)).map(Py.strip).filter { !$0.isEmpty }.prefix(2)
        return lines.count == 2 && Py.equal(lines[0], "Creative Commons Legal Code")
            && Py.equal(lines[1], "CC0 1.0 Universal")
    }

    /// `readme_license_note` on the database's README.md: the upstream README excludes early commits from CC0,
    /// keep that remark next to the license id. Nil when the README has no such remark or is over 1 MiB.
    public static func licenseNote(readme data: Data) -> String? {
        guard data.count <= ImportLimits.maxFileBytes else { return nil }
        // re.search(r"[Cc]ommits prior to \[?`?([0-9a-f]{7,40})", text)
        let text = Py.scalars(Py.decodeUTF8(data))
        let phrase = Array("ommits prior to ".unicodeScalars)
        for start in text.indices where text[start] == "C" || text[start] == "c" {
            var i = start + 1
            guard text[i...].starts(with: phrase) else { continue }
            i += phrase.count
            if i < text.count && text[i] == "[" { i += 1 }
            if i < text.count && text[i] == "`" { i += 1 }
            let sha = text[i...].prefix(40).prefix(while: Py.isLowerHex)
            if sha.count >= 7 {
                return "The upstream README states that commits prior to \(Py.string(sha)) are not covered by the "
                    + "CC0-1.0 license; see docs/ir/profiles.md."
            }
        }
        return nil
    }

    /// Decodes a database text file like the Python importer: one leading BOM dropped, invalid UTF-8 replaced.
    public static func decodeText(_ data: Data) -> String { Py.decodeUTF8(data) }
}
