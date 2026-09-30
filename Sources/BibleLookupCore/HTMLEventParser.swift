import Foundation

/// An event-based HTML reader that behaves like Python's html.parser.HTMLParser
/// (with convert_charrefs=True), which the Python version's text parsers were built on:
///   - tag and attribute names are lowercased, attribute values unescaped
///   - text between tags arrives as one handleData call, entities decoded
///   - <br/> style self-closing tags send handleStartTag then handleEndTag;
///     a plain <br> sends only handleStartTag (no implied end tags, no tree)
///   - comments, <!DOCTYPE> and <?...?> are skipped; <script>/<style> contents are raw text
class HTMLEventParser {
    typealias Attrs = [(String, String?)]

    func handleStartTag(_ tag: String, _ attrs: Attrs) {}
    func handleEndTag(_ tag: String) {}
    func handleData(_ data: String) {}

    /// Last value of an attribute, like Python's dict(attrs).get(name).
    static func attr(_ attrs: Attrs, _ name: String) -> String? {
        attrs.last(where: { $0.0 == name })?.1 ?? nil
    }

    func feed(_ html: String) {
        let s = Array(html.unicodeScalars)
        let n = s.count
        var i = 0
        var cdata: String? = nil  // inside <script> or <style>

        func text(_ a: Int, _ b: Int) -> String {
            var u = String.UnicodeScalarView()
            u.append(contentsOf: s[a..<b])
            return String(u)
        }
        func find(_ needle: String, from: Int, ignoreCase: Bool = false) -> Int? {
            let t = Array((ignoreCase ? needle.lowercased() : needle).unicodeScalars)
            guard t.count <= n else { return nil }
            var k = from
            while k + t.count <= n {
                var ok = true
                for (o, c) in t.enumerated() {
                    var x = s[k + o]
                    if ignoreCase, x.isASCII, x.properties.isUppercase { x = Unicode.Scalar(x.value + 32)! }
                    if x != c { ok = false; break }
                }
                if ok { return k }
                k += 1
            }
            return nil
        }
        func isLetter(_ k: Int) -> Bool {
            k < n && s[k].isASCII && s[k].properties.isAlphabetic
        }
        func isSpace(_ c: Unicode.Scalar) -> Bool {
            c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}"
        }

        while i < n {
            if let elem = cdata {
                let end = find("</" + elem, from: i, ignoreCase: true) ?? n
                if end > i { handleData(text(i, end)) }
                i = end
                cdata = nil
                if i >= n { break }
            }
            var j = i
            while j < n && s[j] != "<" { j += 1 }
            if j > i { handleData(unescapeHTML(text(i, j))) }
            i = j
            if i >= n { break }

            // s[i] == "<"
            if isLetter(i + 1) {
                // start tag
                var k = i + 1
                let nameStart = k
                while k < n && !isSpace(s[k]) && s[k] != "/" && s[k] != ">" && s[k] != "\0" { k += 1 }
                let name = text(nameStart, k).lowercased()
                var attrs: Attrs = []
                var selfClosing = false
                var closed = false
                while k < n {
                    while k < n && (isSpace(s[k]) || s[k] == "/") {
                        if s[k] == "/" && k + 1 < n && s[k + 1] == ">" { selfClosing = true }
                        k += 1
                    }
                    if k >= n { break }
                    if s[k] == ">" { closed = true; k += 1; break }
                    let an = k
                    while k < n && !isSpace(s[k]) && s[k] != "/" && s[k] != ">" && (s[k] != "=" || k == an) { k += 1 }
                    let attrName = text(an, k).lowercased()
                    var ws = k
                    while ws < n && isSpace(s[ws]) { ws += 1 }
                    if ws < n && s[ws] == "=" {
                        k = ws + 1
                        while k < n && isSpace(s[k]) { k += 1 }
                        var value = ""
                        if k < n && (s[k] == "\"" || s[k] == "'") {
                            let q = s[k]
                            let vs = k + 1
                            var ve = vs
                            while ve < n && s[ve] != q { ve += 1 }
                            value = text(vs, ve)
                            k = min(ve + 1, n)
                        } else {
                            let vs = k
                            while k < n && !isSpace(s[k]) && s[k] != ">" { k += 1 }
                            value = text(vs, k)
                        }
                        attrs.append((attrName, unescapeHTML(value)))
                    } else {
                        attrs.append((attrName, nil))
                    }
                }
                if !closed {  // unfinished tag at the end: Python gives it back as text on close()
                    handleData(text(i, n))
                    break
                }
                handleStartTag(name, attrs)
                if selfClosing {
                    handleEndTag(name)
                } else if name == "script" || name == "style" {
                    cdata = name
                }
                i = k
            } else if i + 1 < n && s[i + 1] == "/" {
                guard let gt = find(">", from: i + 2) else { handleData(text(i, n)); break }
                var k = i + 2
                if isLetter(k) {
                    let ns = k
                    while k < gt && !isSpace(s[k]) && s[k] != "/" { k += 1 }
                    handleEndTag(text(ns, k).lowercased())
                }  // "</>" and bogus "</ ...>" are ignored
                i = gt + 1
            } else if find("<!--", from: i) == i {
                i = (find("-->", from: i + 4).map { $0 + 3 }) ?? n
            } else if i + 1 < n && (s[i + 1] == "!" || s[i + 1] == "?") {
                i = (find(">", from: i + 2).map { $0 + 1 }) ?? n
            } else {
                handleData("<")
                i += 1
            }
        }
    }

    func close() {}
}

// MARK: - html.unescape

private let entities: [String: String] = {
    var d: [String: String] = [:]
    for line in htmlEntityTable.split(separator: "\n") {
        let parts = line.split(separator: " ")
        var u = String.UnicodeScalarView()
        for hex in parts.dropFirst() {
            if let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) { u.append(sc) }
        }
        d[String(parts[0])] = String(u)
    }
    return d
}()

// numeric references the HTML standard remaps (mostly Windows-1252)
private let invalidCharrefs: [UInt32: String] = [
    0x00: "\u{FFFD}", 0x0d: "\r", 0x80: "\u{20AC}", 0x81: "\u{81}", 0x82: "\u{201A}", 0x83: "\u{0192}",
    0x84: "\u{201E}", 0x85: "\u{2026}", 0x86: "\u{2020}", 0x87: "\u{2021}", 0x88: "\u{02C6}", 0x89: "\u{2030}",
    0x8a: "\u{0160}", 0x8b: "\u{2039}", 0x8c: "\u{0152}", 0x8d: "\u{8D}", 0x8e: "\u{017D}", 0x8f: "\u{8F}",
    0x90: "\u{90}", 0x91: "\u{2018}", 0x92: "\u{2019}", 0x93: "\u{201C}", 0x94: "\u{201D}", 0x95: "\u{2022}",
    0x96: "\u{2013}", 0x97: "\u{2014}", 0x98: "\u{02DC}", 0x99: "\u{2122}", 0x9a: "\u{0161}", 0x9b: "\u{203A}",
    0x9c: "\u{0153}", 0x9d: "\u{9D}", 0x9e: "\u{017E}", 0x9f: "\u{0178}",
]

private func isInvalidCodepoint(_ v: UInt32) -> Bool {
    (0x1...0x8).contains(v) || (0xe...0x1f).contains(v) || (0x7f...0x9f).contains(v)
        || (0xfdd0...0xfdef).contains(v) || v == 0xb || (v & 0xFFFE) == 0xFFFE
}

private let charref = Re("&(#[0-9]+;?|#[xX][0-9a-fA-F]+;?|[^\\t\\n\\f <&#;]{1,32};?)")

/// Python's html.unescape.
func unescapeHTML(_ s: String) -> String {
    guard s.contains("&") else { return s }
    return charref.sub(s) { m in
        let ref = m[1]!
        if ref.hasPrefix("#") {
            var body = ref.dropFirst()
            if body.hasSuffix(";") { body = body.dropLast() }
            let hex = body.first == "x" || body.first == "X"
            guard let num = UInt32(hex ? String(body.dropFirst()) : String(body), radix: hex ? 16 : 10) else {
                return "\u{FFFD}"  // too large to hold
            }
            if let r = invalidCharrefs[num] { return r }
            if (0xD800...0xDFFF).contains(num) || num > 0x10FFFF { return "\u{FFFD}" }
            if isInvalidCodepoint(num) { return "" }
            return String(Unicode.Scalar(num).map(Character.init) ?? "\u{FFFD}")
        }
        if let v = entities[ref] { return v }
        let chars = Array(ref)
        var x = chars.count - 1
        while x > 1 {  // longest legacy name that matches ("&copy2019")
            let prefix = String(chars[0..<x])
            if let v = entities[prefix] { return v + String(chars[x...]) }
            x -= 1
        }
        return "&" + ref
    }
}
