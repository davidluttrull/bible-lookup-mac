import Foundation

/// A compiled regular expression with the handful of Python `re` operations the
/// parsers use (ICU's syntax is close enough to Python's for these patterns).
final class Re: @unchecked Sendable {
    private let rx: NSRegularExpression
    private let full: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false) {
        let opts: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
        rx = try! NSRegularExpression(pattern: pattern, options: opts)
        full = try! NSRegularExpression(pattern: "\\A(?:\(pattern))\\z", options: opts)
    }

    /// Python's re.sub with a function.
    func sub(_ s: String, _ replace: (Match) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += replace(Match(m, ns))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    func sub(_ s: String, _ replacement: String) -> String {
        sub(s) { _ in replacement }
    }

    /// Python's re.match: a match at the start of the string.
    func match(_ s: String) -> Match? {
        let ns = s as NSString
        return rx.firstMatch(in: s, options: .anchored, range: NSRange(location: 0, length: ns.length)).map { Match($0, ns) }
    }

    /// Python's re.fullmatch.
    func fullMatch(_ s: String) -> Match? {
        let ns = s as NSString
        return full.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)).map { Match($0, ns) }
    }

    /// Python's re.search.
    func search(_ s: String) -> Match? {
        let ns = s as NSString
        return rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)).map { Match($0, ns) }
    }

    struct Match {
        let result: NSTextCheckingResult
        let string: NSString

        init(_ r: NSTextCheckingResult, _ s: NSString) {
            result = r
            string = s
        }

        /// A group's text, or nil when it didn't take part (like Python's None).
        subscript(_ i: Int) -> String? {
            guard i < result.numberOfRanges else { return nil }
            let r = result.range(at: i)
            return r.location == NSNotFound ? nil : string.substring(with: r)
        }
    }
}

extension String {
    /// Python's str.strip() (Unicode whitespace).
    var stripped: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Python's str.isupper(): at least one cased letter, and no lowercase ones.
    var isUpper: Bool {
        var cased = false
        for ch in self {
            if ch.isLowercase { return false }
            if ch.isUppercase { cased = true }
        }
        return cased
    }

    /// "LORD" -> "Lord": first character kept, the rest lowercased (Python's w[:1] + w[1:].lower()).
    var firstKeptRestLowered: String {
        guard let first = first else { return self }
        return String(first) + dropFirst().lowercased()
    }
}

/// Python's html.escape(s, quote=False).
func escapeHTML(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        default: out.append(ch)
        }
    }
    return out
}

/// int() for a string of digits (any script's digits, as Python allows).
func parseInt(_ s: String) -> Int? {
    if let n = Int(s) { return n }
    var n = 0
    for ch in s {
        guard let d = ch.wholeNumberValue else { return nil }
        n = n * 10 + d
    }
    return s.isEmpty ? nil : n
}
