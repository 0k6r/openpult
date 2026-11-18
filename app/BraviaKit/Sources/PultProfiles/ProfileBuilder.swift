import Foundation

/// One generated profile (a group of files with the same codes).
struct Profile {
    var id: String
    var brand: String
    var name: String
    var models: [String]
    var weight: Int
    var source: [String]
    var keys: [(key: String, cmd: ProfileCommand)]
    var extra: [Button]

    func command(for key: String) -> ProfileCommand? {
        keys.first { Py.equal($0.key, key) }?.cmd
    }
}

struct PowerScanCode {
    var cmd: ProfileCommand
    var brands: [String]
    var weight: Int
}

struct IndexBrand {
    var id: String
    var name: String
    var file: String
    var profiles: Int
}

/// A file that contributed buttons.
struct FileEntry {
    var source: String
    var keys: [(key: String, cmd: ProfileCommand)]
    var extra: [Button]
    var models: [String]
    var label: String
}

struct BrandEntry {
    var name: String
    var files: [FileEntry]
}

/// The counters of the import report (`Stats`).
struct ImportStats {
    var filesSeen = 0
    var filesUsed = 0
    var skippedFiles: [String: Int] = [:]
    var skippedCodes: [String: Int] = [:]
    var recovered: [String: Int] = [:]
    var examples: [String: [String]] = [:]
    var buttonsIn: [String: Int] = [:]
    var duplicatesDropped = 0
    var names: [PyKey: Int] = [:]            // normalized name -> number of files using it
    var nameExamples: [PyKey: String] = [:]

    mutating func skip(_ reason: String, _ location: String) {
        if reason.utf8.starts(with: "file:".utf8) {
            skippedFiles[reason, default: 0] += 1
        } else if reason.utf8.starts(with: "recovered:".utf8) {
            recovered[reason, default: 0] += 1
        } else {
            skippedCodes[reason, default: 0] += 1
        }
        if examples[reason, default: []].count < 3 {
            examples[reason, default: []].append(location)
        }
    }
}

/// Files -> brands -> profiles (import_flipper_irdb.py, "Import").
enum ProfileBuilder {
    /// The part of `collect` that handles one readable file; `brands` keeps the first display name of an id.
    static func collect(text: String, rel: String, source: String, aliases: KeyAliases,
                        brands: inout [String: BrandEntry], stats: inout ImportStats) {
        let (buttons, errors) = IRFileParser.parseIRText(text)
        for (reason, count) in errors.sorted(by: { Py.less($0.key, $1.key) }) {
            for _ in 0..<count {
                stats.skip(reason, source)
            }
        }
        if errors[IRFileParser.notIRFile] != nil {
            return
        }
        if buttons.isEmpty {
            stats.skip("file: no usable buttons", source)
            return
        }
        let brand = ProfileNames.brandOf(rel)
        let brandID = ProfileNames.slugify(brand)
        if brandID.isEmpty {
            stats.skip("file: brand name without letters or digits", source)
            return
        }
        for norm in Set(buttons.map { PyKey(ProfileNames.normalizeName($0.name)) }) {
            stats.names[norm, default: 0] += 1
        }
        for button in buttons {
            let norm = PyKey(ProfileNames.normalizeName(button.name))
            if stats.nameExamples[norm] == nil {
                stats.nameExamples[norm] = button.name
            }
            stats.buttonsIn[button.cmd.isRaw ? "raw" : "parsed", default: 0] += 1
        }
        let mapped = ButtonMapper.mapButtons(buttons, aliases: aliases)
        stats.duplicatesDropped += mapped.dropped
        let (models, label) = ProfileNames.fileLabel(rel, brand: brand)
        let entry = FileEntry(source: source, keys: mapped.keys, extra: mapped.extra, models: models, label: label)
        brands[brandID, default: BrandEntry(name: brand, files: [])].files.append(entry)
        stats.filesUsed += 1
    }

    /// `build_profiles`: the files of one brand grouped by identical codes, most common first.
    static func buildProfiles(brandID: String, brand: String, files: [FileEntry], keyOrder: [String]) -> [Profile] {
        struct Signature: Hashable {
            var keys: [String]     // canonical "[key, cmd]" pairs in key order
            var extra: [String]    // sorted canonical commands
        }
        var order: [Signature] = []
        var groups: [Signature: [FileEntry]] = [:]
        for file in files.sorted(by: { Py.less($0.source, $1.source) }) {
            // Keys are already in key order; canonical() is ASCII, so String hashing is exact.
            let sig = Signature(keys: file.keys.map { ProfileWriter.quote($0.key, ensureASCII: true) + $0.cmd.canonical },
                                extra: file.extra.map(\.cmd.canonical).sorted(by: Py.less))
            if groups[sig] == nil {
                order.append(sig)
            }
            groups[sig, default: []].append(file)
        }
        var profiles: [Profile] = []
        for sig in order {
            let members = groups[sig]!
            let first = members[0]
            var unique = Set<PyKey>()
            for file in members {
                for model in file.models {
                    unique.insert(PyKey(model))
                }
            }
            let models = unique.sorted { a, b in
                let la = PyKey(Py.lower(a.value)), lb = PyKey(Py.lower(b.value))
                return la != lb ? la < lb : a < b
            }.map(\.value)
            let label = members.first { !$0.label.isEmpty }?.label ?? ""
            profiles.append(Profile(
                id: "",
                brand: brand,
                name: ProfileNames.profileName(brand: brand, models: models, label: label),
                models: models,
                weight: members.count,
                source: members.map(\.source).sorted(by: Py.less),
                keys: first.keys,
                extra: first.extra
            ))
        }
        profiles.sort { a, b in
            if a.weight != b.weight { return a.weight > b.weight }
            if a.keys.count != b.keys.count { return a.keys.count > b.keys.count }
            if a.extra.count != b.extra.count { return a.extra.count > b.extra.count }
            return Py.less(a.source[0], b.source[0])
        }
        var seen: [PyKey: Int] = [:]
        for i in profiles.indices {
            let name = PyKey(profiles[i].name)
            seen[name, default: 0] += 1
            if seen[name]! > 1 {
                profiles[i].name = "\(profiles[i].name) #\(seen[name]!)"
            }
            profiles[i].id = "\(brandID)-\(i + 1)"
        }
        return profiles
    }

    /// `build_power_scan`: unique power codes across all brands, most common first.
    static func buildPowerScan(_ profiles: [Profile]) -> [PowerScanCode] {
        struct Entry {
            var cmd: ProfileCommand
            var brandOrder: [String] = []
            var brandWeight: [PyKey: Int] = [:]
            var weight = 0
        }
        var order: [String] = []
        var codes: [String: Entry] = [:]
        for p in profiles {
            guard let cmd = p.command(for: "power") ?? p.command(for: "wakeUp") else { continue }
            let c = cmd.canonical
            if codes[c] == nil {
                order.append(c)
                codes[c] = Entry(cmd: cmd)
            }
            let brand = PyKey(p.brand)
            if codes[c]!.brandWeight[brand] == nil {
                codes[c]!.brandOrder.append(p.brand)
            }
            codes[c]!.brandWeight[brand, default: 0] += p.weight
            codes[c]!.weight += p.weight
        }
        var out: [(canonical: String, code: PowerScanCode)] = order.map { c in
            let e = codes[c]!
            let brands = e.brandOrder.sorted { a, b in
                let wa = e.brandWeight[PyKey(a)]!, wb = e.brandWeight[PyKey(b)]!
                if wa != wb { return wa > wb }
                let la = PyKey(Py.lower(a)), lb = PyKey(Py.lower(b))
                return la != lb ? la < lb : Py.less(a, b)
            }
            return (c, PowerScanCode(cmd: e.cmd, brands: brands, weight: e.weight))
        }
        out.sort { a, b in
            if a.code.weight != b.code.weight { return a.code.weight > b.code.weight }
            if a.code.brands.count != b.code.brands.count { return a.code.brands.count > b.code.brands.count }
            return Py.less(a.canonical, b.canonical)
        }
        return out.map(\.code)
    }
}
