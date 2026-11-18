import Foundation

/// Button, brand, model and profile names (import_flipper_irdb.py, "Names" and "Files, brands and models").
enum ProfileNames {
    static let maxNameChars = 40
    static let maxLabelChars = 48
    static let maxProfileName = 100   // before a possible " #N" suffix
    static let labelStopwords: Set<PyKey> = [PyKey("tv"), PyKey("remote"), PyKey("ir")]

    /// `normalize_name`: lowercase, drop whitespace and "_", drop "-" unless it is the last character.
    static func normalizeName(_ name: String) -> String {
        // re.sub(r"[\s_]+", "", name.lower()), then re.sub(r"-(?=.)", "", s); no "\n" is left for "." to miss.
        let kept = Py.lower(name).unicodeScalars.filter { !Py.isSpace($0) && $0 != "_" }
        var out = String.UnicodeScalarView()
        for (i, c) in kept.enumerated() where !(c == "-" && i < kept.count - 1) {
            out.append(c)
        }
        return String(out)
    }

    /// `clean_text`: remove control/format characters (incl. bidi overrides), collapse whitespace, cap the length.
    static func cleanText(_ text: String, limit: Int = maxNameChars) -> String {
        let kept = Py.string(text.unicodeScalars.filter { !Py.isOther($0) })
        let collapsed = Py.strip(Py.replaceRuns(kept, where: Py.isSpace, with: " "))
        return Py.rstrip(Py.prefix(collapsed, limit))
    }

    /// `slugify`: NFKD, drop non-ASCII, lowercase, runs of anything but [a-z0-9] become "-".
    static func slugify(_ name: String) -> String {
        let ascii = Py.string(name.decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII))
        let dashed = Py.replaceRuns(Py.lower(ascii), where: { !Py.isASCIILower($0) && !Py.isASCIIDigit($0) },
                                    with: "-")
        return Py.strip(dashed, characters: "-")
    }

    /// `name[:-3] if name.lower().endswith(".ir") else name`.
    static func dropIRExtension(_ name: String) -> String {
        guard Py.ends(Py.lower(name), with: ".ir") else { return name }
        return Py.string(name.unicodeScalars.dropLast(3))
    }

    /// `brand_of`: the folder under TVs/, or the first word of a file placed directly in TVs/.
    static func brandOf(_ rel: String) -> String {
        let parts = Py.split(rel, separator: "/")
        if parts.count > 1 {
            return cleanText(parts[0])
        }
        let stem = dropIRExtension(parts[0])
        return cleanText(Py.splitRuns(Py.strip(stem)) { Py.isSpace($0) || $0 == "_" }[0])
    }

    /// `looks_like_model`: "BN59-01175N", "32LF650V", "RM-YD018": letters and digits, and either 2+ digits or
    /// upper-case letters.
    static func looksLikeModel(_ token: String) -> Bool {
        var a = Py.scalars(token)
        // Both patterns end in "$", which also matches before one trailing "\n".
        if a.last == "\n" {
            a.removeLast()
        }
        // MODEL_RE = ^(?=.*[A-Za-z])(?=.*\d)[A-Za-z0-9][A-Za-z0-9.\-/+]{2,31}$
        guard (3...32).contains(a.count), Py.isASCIIAlnum(a[0]),
              a.dropFirst().allSatisfy({ Py.isASCIIAlnum($0) || "./+-".unicodeScalars.contains($0) }),
              a.contains(where: Py.isASCIILetter), a.contains(where: Py.isASCIIDigit)
        else { return false }
        if isNotModel(a) {
            return false
        }
        let digits = a.filter(Py.isASCIIDigit).count
        return digits >= 2 || a.filter(Py.isASCIILetter).allSatisfy(Py.isASCIIUpper)
    }

    /// NOT_MODEL_RE = ^(\d{3,4}[pi]|[248]k(uhd)?|\d+(inch|in)|v\d+)$ with re.IGNORECASE, on an ASCII token.
    private static func isNotModel(_ a: [Unicode.Scalar]) -> Bool {
        let s = Py.lower(Py.string(a))
        let chars = Array(s.unicodeScalars)
        let leadingDigits = chars.prefix(while: Py.isASCIIDigit).count
        let rest = Py.string(chars[leadingDigits...])
        if (3...4).contains(leadingDigits) && (rest == "p" || rest == "i") {
            return true
        }
        if ["2k", "4k", "8k", "2kuhd", "4kuhd", "8kuhd"].contains(s) {
            return true
        }
        if leadingDigits >= 1 && (rest == "inch" || rest == "in") {
            return true
        }
        if chars.first == "v" && chars.count >= 2 && chars.dropFirst().allSatisfy(Py.isASCIIDigit) {
            return true
        }
        return false
    }

    /// `re.sub(r"\(.*?\)", " ", s)`: each "(" up to the next ")" on the same line becomes one space.
    static func removeParentheses(_ s: String) -> String {
        let a = Py.scalars(s)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < a.count {
            if a[i] == "(" {
                var j = i + 1
                while j < a.count && a[j] != ")" && a[j] != "\n" { j += 1 }
                if j < a.count && a[j] == ")" {
                    out.append(" ")
                    i = j + 1
                    continue
                }
            }
            out.append(a[i])
            i += 1
        }
        return String(out)
    }

    /// `file_label`: (models, label) taken from the file name.
    static func fileLabel(_ rel: String, brand: String) -> (models: [String], label: String) {
        let name = Py.split(rel, separator: "/").last!
        let stem = removeParentheses(dropIRExtension(name))
        var tokens = Py.splitRuns(stem) { Py.isSpace($0) || $0 == "_" || $0 == "," }.filter { !$0.isEmpty }
        var brandTokens = Set(Py.splitRuns(brand) { Py.isSpace($0) || $0 == "_" || $0 == "-" }
            .map { PyKey(normalizeName($0)) })
        brandTokens.insert(PyKey(normalizeName(brand)))
        tokens = tokens.filter { !brandTokens.contains(PyKey(normalizeName($0))) }
        var models: [String] = []
        for token in tokens {
            let t = cleanText(Py.strip(token, characters: ".-/+"))
            if looksLikeModel(t) && !models.contains(where: { Py.equal($0, t) }) {
                models.append(t)
            }
        }
        let words = tokens.filter { !labelStopwords.contains(PyKey(Py.lower($0))) }
        return (models, cleanText(words.joined(separator: " "), limit: maxLabelChars))
    }

    /// `profile_name`.
    static func profileName(brand: String, models: [String], label: String) -> String {
        var name: String
        if !models.isEmpty {
            var shown = models.prefix(3).joined(separator: ", ")
            if models.count > 3 {
                shown += " +\(models.count - 3)"
            }
            name = "\(brand) TV (\(shown))"
        } else if !label.isEmpty {
            name = "\(brand) TV (\(label))"
        } else {
            name = "\(brand) TV"
        }
        if Py.count(name) > maxProfileName {
            name = Py.rstrip(Py.prefix(name, maxProfileName - 2)) + "…)"
        }
        return name
    }

    /// `safe_path_text`: no control/format/unassigned characters, bounded length.
    static func isSafePath(_ rel: String) -> Bool {
        Py.count(rel) <= ImportLimits.maxPathChars && !rel.unicodeScalars.contains(where: Py.isOther)
    }
}
