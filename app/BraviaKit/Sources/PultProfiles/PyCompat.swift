import Foundation

/// The Python 3 string semantics that tools/profiles/import_flipper_irdb.py relies on.
///
/// Everything works on Unicode scalars (Python code points), never on `Character`s: Swift's `==`, `<`,
/// `hasPrefix` and `Dictionary` lookups on `String` use canonical equivalence and grapheme clusters, so
/// "e\u{301}" == "é" and "\u{212A}" == "K" in Swift but not in Python. Code that must agree with Python compares
/// strings with `Py.equal` / `Py.less` or keys dictionaries with `PyKey`.
///
/// Character properties come from the Swift runtime's Unicode tables (shipped with the OS on Apple platforms:
/// Unicode 17 on macOS 27, older on iOS 17/18), Python's from `unicodedata` (16.0 in Python 3.14). They agree on
/// characters assigned in both versions, with one known exception: U+0295 is cased only in Unicode 16 (Final_Sigma).
/// A name with a character assigned in only one version can therefore be cleaned differently, or its file rejected
/// as unsafe on one side only. Flipper-IRDB's TVs/ folder is pure ASCII (commit d126fb1), so its output is unaffected.
enum Py {
    // MARK: Character classes

    /// `str.isspace()`; also the `\s` class of `re` and the separators of `str.split()` / `str.strip()`.
    static func isSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// The line boundaries of `str.splitlines()`.
    static func isLineBreak(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x0A...0x0D, 0x1C...0x1E, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    /// `unicodedata.category(c)[0] == "C"`: control, format, surrogate, private use or unassigned.
    static func isOther(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x00..<0x20, 0x7F...0x9F:
            return true
        case 0x20..<0x7F:
            return false
        default:
            switch c.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned:
                return true
            default:
                return false
            }
        }
    }

    static func isASCIIDigit(_ c: Unicode.Scalar) -> Bool { (0x30...0x39).contains(c.value) }
    static func isASCIIUpper(_ c: Unicode.Scalar) -> Bool { (0x41...0x5A).contains(c.value) }
    static func isASCIILower(_ c: Unicode.Scalar) -> Bool { (0x61...0x7A).contains(c.value) }
    static func isASCIILetter(_ c: Unicode.Scalar) -> Bool { isASCIIUpper(c) || isASCIILower(c) }
    static func isASCIIAlnum(_ c: Unicode.Scalar) -> Bool { isASCIILetter(c) || isASCIIDigit(c) }
    static func isLowerHex(_ c: Unicode.Scalar) -> Bool { isASCIIDigit(c) || (0x61...0x66).contains(c.value) }
    static func isHex(_ c: Unicode.Scalar) -> Bool {
        isASCIIDigit(c) || (0x41...0x46).contains(c.value) || (0x61...0x66).contains(c.value)
    }

    // MARK: Building and comparing

    static func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }

    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// Python `a == b`: the same code points.
    static func equal(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    /// Python `a < b`: code point order, which is also UTF-8 byte order.
    static func less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    /// `len(s)`.
    static func count(_ s: String) -> Int { s.unicodeScalars.count }

    /// `s[:n]`.
    static func prefix(_ s: String, _ n: Int) -> String { string(s.unicodeScalars.prefix(max(n, 0))) }

    /// `s.startswith(c)` for a single code point.
    static func starts(_ s: String, with c: Unicode.Scalar) -> Bool { s.unicodeScalars.first == c }

    /// `s.endswith(suffix)`.
    static func ends(_ s: String, with suffix: String) -> Bool {
        let a = Array(s.utf8), b = Array(suffix.utf8)
        return a.count >= b.count && a[(a.count - b.count)...].elementsEqual(b)
    }

    // MARK: str methods

    /// `s.strip()`.
    static func strip(_ s: String) -> String { strip(s, where: isSpace) }

    /// `s.rstrip()`.
    static func rstrip(_ s: String) -> String {
        let a = scalars(s)
        guard let last = a.lastIndex(where: { !isSpace($0) }) else { return "" }
        return string(a[...last])
    }

    /// `s.strip(chars)`.
    static func strip(_ s: String, characters: String) -> String {
        let set = Set(characters.unicodeScalars)
        return strip(s) { set.contains($0) }
    }

    static func strip(_ s: String, where predicate: (Unicode.Scalar) -> Bool) -> String {
        let a = scalars(s)
        guard let first = a.firstIndex(where: { !predicate($0) }), let last = a.lastIndex(where: { !predicate($0) })
        else { return "" }
        return string(a[first...last])
    }

    /// `s.split()`: runs of whitespace, no empty pieces.
    static func split(_ s: String) -> [String] {
        splitRuns(s, where: isSpace).filter { !$0.isEmpty }
    }

    /// `s.split(sep)` for a single-code-point separator: every occurrence, empty pieces kept.
    static func split(_ s: String, separator: Unicode.Scalar) -> [String] {
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            if c == separator {
                pieces.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(c)
            }
        }
        pieces.append(String(current))
        return pieces
    }

    /// `re.split(r"[...]+", s)` for a character class: one cut per run, leading/trailing empty pieces kept.
    static func splitRuns(_ s: String, where isSeparator: (Unicode.Scalar) -> Bool) -> [String] {
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        var inRun = false
        for c in s.unicodeScalars {
            if isSeparator(c) {
                if !inRun {
                    pieces.append(String(current))
                    current = String.UnicodeScalarView()
                    inRun = true
                }
            } else {
                inRun = false
                current.append(c)
            }
        }
        pieces.append(String(current))
        return pieces
    }

    /// `re.sub(r"[...]+", replacement, s)` for a character class.
    static func replaceRuns(_ s: String, where isMember: (Unicode.Scalar) -> Bool, with replacement: String) -> String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for c in s.unicodeScalars {
            if isMember(c) {
                if !inRun {
                    out.append(contentsOf: replacement.unicodeScalars)
                    inRun = true
                }
            } else {
                inRun = false
                out.append(c)
            }
        }
        return String(out)
    }

    /// `s.splitlines()`: "\r\n" is one break, a trailing break adds no empty line.
    static func splitLines(_ s: String) -> [String] {
        let a = scalars(s)
        var lines: [String] = []
        var i = 0
        while i < a.count {
            let start = i
            while i < a.count && !isLineBreak(a[i]) { i += 1 }
            lines.append(string(a[start..<i]))
            if i < a.count {
                i += (a[i] == "\r" && i + 1 < a.count && a[i + 1] == "\n") ? 2 : 1
            }
        }
        return lines
    }

    /// `s.partition(sep)` for a single code point; nil when `sep` does not occur.
    static func partition(_ s: String, _ separator: Unicode.Scalar) -> (String, String)? {
        let a = scalars(s)
        guard let index = a.firstIndex(of: separator) else { return nil }
        return (string(a[..<index]), string(a[(index + 1)...]))
    }

    /// `s.lower()`: full lowercase mapping plus the Final_Sigma rule for U+03A3.
    static func lower(_ s: String) -> String {
        if s.utf8.allSatisfy({ $0 < 0x80 }) {
            return string(s.unicodeScalars.map { isASCIIUpper($0) ? Unicode.Scalar($0.value + 0x20)! : $0 })
        }
        let a = scalars(s)
        var out = String.UnicodeScalarView()
        for (i, c) in a.enumerated() {
            if c.isASCII {
                out.append(isASCIIUpper(c) ? Unicode.Scalar(c.value + 0x20)! : c)
            } else if c.value == 0x3A3 {
                out.append(isFinalSigma(a, at: i) ? "\u{3C2}" : "\u{3C3}")
            } else {
                out.append(contentsOf: c.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(out)
    }

    /// CPython's handle_capital_sigma: \p{cased}\p{case-ignorable}* U+03A3 !(\p{case-ignorable}* \p{cased}).
    private static func isFinalSigma(_ a: [Unicode.Scalar], at i: Int) -> Bool {
        var j = i - 1
        while j >= 0 && isCaseIgnorable(a[j]) { j -= 1 }
        guard j >= 0 && a[j].properties.isCased else { return false }
        j = i + 1
        while j < a.count && isCaseIgnorable(a[j]) { j += 1 }
        return j == a.count || !a[j].properties.isCased
    }

    /// Case_Ignorable as in the Unicode data; Apple's tables also mark some private-use code points.
    private static func isCaseIgnorable(_ c: Unicode.Scalar) -> Bool {
        c.properties.isCaseIgnorable && c.properties.generalCategory != .privateUse
    }

    /// `ascii(s)`: the repr of a str with every non-ASCII code point escaped.
    static func ascii(_ s: String) -> String {
        let a = scalars(s)
        let quote: Unicode.Scalar = a.contains("'") && !a.contains("\"") ? "\"" : "'"
        var out = String.UnicodeScalarView()
        out.append(quote)
        func escape(_ prefix: String, _ value: UInt32, _ width: Int) {
            let digits = String(value, radix: 16)
            out.append(contentsOf: (prefix + String(repeating: "0", count: max(0, width - digits.count)) + digits)
                .unicodeScalars)
        }
        for c in a {
            switch c {
            case quote, "\\":
                out.append("\\")
                out.append(c)
            case "\t":
                out.append(contentsOf: "\\t".unicodeScalars)
            case "\n":
                out.append(contentsOf: "\\n".unicodeScalars)
            case "\r":
                out.append(contentsOf: "\\r".unicodeScalars)
            default:
                let v = c.value
                if v < 0x20 || v == 0x7F {
                    escape("\\x", v, 2)
                } else if v < 0x7F {
                    out.append(c)
                } else if v < 0x100 {
                    escape("\\x", v, 2)
                } else if v < 0x10000 {
                    escape("\\u", v, 4)
                } else {
                    escape("\\U", v, 8)
                }
            }
        }
        out.append(quote)
        return String(out)
    }

    // MARK: Bytes and numbers

    /// `data.decode("utf-8", errors="replace")` after dropping one leading UTF-8 BOM. Both Python and Swift
    /// replace each maximal ill-formed subsequence with one U+FFFD.
    static func decodeUTF8(_ data: Data) -> String {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let body = data.starts(with: bom) ? data.dropFirst(3) : data[...]
        return String(decoding: body, as: UTF8.self)
    }

    /// `round(x)` for a float: round half to even.
    static func round(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }

    /// `a // b` for ints.
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}

/// A `String` dictionary key / sort key with Python semantics: equal only for the same code points, ordered by
/// code point.
struct PyKey: Hashable, Comparable, CustomStringConvertible {
    let value: String

    init(_ value: String) { self.value = value }

    static func == (a: PyKey, b: PyKey) -> Bool { Py.equal(a.value, b.value) }
    static func < (a: PyKey, b: PyKey) -> Bool { Py.less(a.value, b.value) }

    func hash(into hasher: inout Hasher) {
        var copy = value
        copy.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }

    var description: String { value }
}
