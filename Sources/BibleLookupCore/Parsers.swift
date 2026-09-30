import Foundation

// Turning each source's HTML into verses. These follow the Python version's parsers
// (python-reference/providers.py) event for event; the tests check both give the same
// output on recorded responses.
//
// Verse html only ever contains <i>, <br>, and <span class="nd|wj"> that we build
// ourselves; all source text is escaped first.

public final class Verse: @unchecked Sendable {
    public var c: Int
    public var v: Int
    public var h: String
    public var p: Bool
    public var s: String?  // section heading
    public var t: String?  // title (psalm title, speaker, textual note)

    init(c: Int, v: Int, h: String = "", p: Bool = false, s: String? = nil, t: String? = nil) {
        self.c = c
        self.v = v
        self.h = h
        self.p = p
        self.s = s
        self.t = t
    }

    public var json: [String: Any] {
        var d: [String: Any] = ["c": c, "v": v, "h": h, "p": p]
        if let s = s { d["s"] = s }
        if let t = t { d["t"] = t }
        return d
    }
}

private let spaces = Re("\\s+")
private let brRuns = Re("(\\s*<br>\\s*)+")
private let brEnds = Re("^(<br>)+|(<br>)+$")
private let divineName = Re("\\b(LORD|GOD)\\b")

func cleanSpace(_ s: String) -> String {
    var s = spaces.sub(s, " ")
    s = brRuns.sub(s, "<br>")
    return brEnds.sub(s.stripped, "").stripped
}

/// Divine name printed in capitals (LORD, GOD) -> small caps, as in print.
func smallCapsLord(_ s: String) -> String {
    divineName.sub(s) { m in "<span class=\"nd\">\(m[1]!.prefix(1))\(m[1]!.dropFirst().lowercased())</span>" }
}

private func classes(_ attrs: HTMLEventParser.Attrs) -> [String] {
    (HTMLEventParser.attr(attrs, "class") ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

// MARK: - shared machinery (Python: _VerseHTML)

/// Subclasses map their source's tags onto these calls:
///   startBlock()        a paragraph or poetry line begins
///   startVerse(c, v)    a verse number
///   openSpan(o, c)      inline markup we keep (red letters, small caps, italics)
///   plainSpan()         inline markup we ignore (keeps open/close tags paired)
///   text(data)          text content
/// Text at the start of a block is held back until we know whether it continues the
/// current verse (then it goes on a new line) or leads into the next verse number
/// (like the "[[" before Mark 16:9).
class VerseHTMLParser: HTMLEventParser {
    private static let prefixOnly = Re("[\\s\\[\\]“‘(]*")
    private static let bookDivision = Re("book [\\divxlc]+\\.?", ignoreCase: true)

    var verses: [Verse] = []
    var cur: Verse? = nil
    var skip = 0              // depth inside an element we drop
    var inNum = false         // inside the verse-number element
    var title: String? = nil  // collecting a title (psalm title, speaker, note)
    var titleKind = "t"       // ...or a section heading ("s")
    var pendingTitles: [String: String] = [:]  // kind -> text, attached to the next verse
    var blockStart = false
    var pending = ""
    var closers: [String] = []  // one entry per open span

    private func add(_ text: String) {
        cur!.h += smallCapsLord(escapeHTML(text))
    }

    private func flushPending() {
        // a new paragraph/line that continues the current verse starts on a new line
        // (a trailing <br> left by a block that ends up empty is trimmed by cleanSpace)
        if blockStart, cur != nil {
            cur!.h += "<br>"
            add(pending)
        }
        pending = ""
        blockStart = false
    }

    func startBlock() {
        flushPending()
        blockStart = true
    }

    func startVerse(_ c: Int, _ v: Int) {
        let prefix = pending.stripped
        cur = Verse(c: c, v: v, p: blockStart, s: pendingTitles["s"], t: pendingTitles["t"])
        pendingTitles = [:]
        verses.append(cur!)
        if !prefix.isEmpty { add(prefix) }
        pending = ""
        blockStart = false
        inNum = true
    }

    func startTitle(_ kind: String = "t") {
        title = ""
        titleKind = kind
    }

    func endTitle() {
        if let t = title, !t.stripped.isEmpty {
            let text = spaces.sub(t, " ").stripped
            // the Psalms' book divisions ("BOOK 2") go above the section heading
            let kind = Self.bookDivision.fullMatch(text) != nil ? "s" : titleKind
            // several before one verse stack up
            if let prev = pendingTitles[kind] {
                pendingTitles[kind] = "\(prev)\n\(text)"
            } else {
                pendingTitles[kind] = text
            }
        }
        title = nil
    }

    func openSpan(_ open: String, _ close: String) {
        if cur == nil || title != nil { return plainSpan() }
        flushPending()
        cur!.h += open
        closers.append(close)
    }

    func plainSpan() {
        closers.append("")
    }

    func closeSpan() {
        if let close = closers.popLast(), !close.isEmpty, cur != nil {
            cur!.h += close
        }
    }

    func text(_ data: String) {
        if skip > 0 || inNum { return }
        if title != nil {
            title! += data
            return
        }
        let data = data.replacingOccurrences(of: "\u{A0}", with: " ")
        if blockStart {
            pending += data
            if Self.prefixOnly.fullMatch(pending) == nil { flushPending() }
            return
        }
        if cur != nil { add(data) }
    }

    override func handleData(_ data: String) { text(data) }

    func result() -> [Verse] {
        for v in verses { v.h = cleanSpace(v.h) }
        return verses
    }
}

// MARK: - ESV

/// Verse markers look like <b class="verse-num" id="v43003016-1"> (book, chapter,
/// verse packed into the id). Section headings (h3) become the next verse's
/// heading; psalm titles, Psalm 119 letters, Song of Songs speakers and textual
/// notes (h4) become its title. Other h4s are dropped.
final class ESVParser: VerseHTMLParser {
    private static let titleClasses: Set<String> = ["psalm-title", "psalm-acrostic-title", "textual-note", "speaker"]
    private static let verseId = Re("v\\d{2}(\\d{3})(\\d{3})")

    override func handleStartTag(_ tag: String, _ attrs: Attrs) {
        let cls = classes(attrs)
        if skip > 0 {
            if tag != "br" { skip += 1 }
            return
        }
        if tag == "h4" && Self.titleClasses.isDisjoint(with: cls) {
            skip = 1
        } else if tag == "h3" {
            startTitle("s")
        } else if tag == "h4" {
            startTitle()
        } else if tag == "b" && (cls.contains("verse-num") || cls.contains("chapter-num")) {
            if let m = Self.verseId.match(Self.attr(attrs, "id") ?? "") {
                startVerse(parseInt(m[1]!)!, parseInt(m[2]!)!)
            }
        } else if tag == "p" {
            startBlock()
        } else if tag == "span" && cls.contains("line") {
            startBlock()
            plainSpan()
        } else if tag == "span" {
            if cls.contains("woc") {
                openSpan("<span class=\"wj\">", "</span>")
            } else if cls.contains("divine-name") {
                openSpan("<span class=\"nd\">", "</span>")
            } else if cls.contains("selah") {
                openSpan("<i>", "</i>")
            } else {
                plainSpan()
            }
        }
    }

    override func handleEndTag(_ tag: String) {
        if skip > 0 {
            skip -= 1
            return
        }
        if tag == "h3" || tag == "h4" {
            endTitle()
        } else if tag == "b" {
            inNum = false
        } else if tag == "span" {
            closeSpan()
        }
    }
}

// MARK: - NLT

/// Pull verses out of the NLT API's HTML, skipping footnotes and headings other
/// than section headings (<h3|h4 class="subhead">, found inside the verse they introduce).
final class NLTParser: HTMLEventParser {
    private static let skipTags: Set<String> = ["h1", "h2", "h3", "h4", "h5"]

    var verses: [Verse] = []
    private var cur: Verse? = nil
    private var skip = 0            // depth inside something we drop
    private var stack: [(String, String)] = []  // open tags inside the current verse: (tag, emitted close)
    private var title: String? = nil
    private var inTitle = false
    private var heading: String? = nil  // text of the section heading being read
    private var headingNote: Int? = nil  // skip depth of a footnote inside it

    override func handleStartTag(_ tag: String, _ attrs: Attrs) {
        let cls = Self.attr(attrs, "class") ?? ""
        if tag == "verse_export" {
            let v = Verse(c: parseInt(Self.attr(attrs, "ch") ?? "") ?? 0, v: parseInt(Self.attr(attrs, "vn") ?? "") ?? 0)
            cur = v
            verses.append(v)
            stack = []
            return
        }
        guard let cur = cur else { return }
        if skip > 0 {
            if tag != "br" { skip += 1 }
            if heading != nil && headingNote == nil && (tag == "a" || cls == "tn" || cls == "a-tn") {
                headingNote = skip
            }
            return
        }
        if Self.skipTags.contains(tag) || cls == "vn" || cls == "tn" || cls == "a-tn" || tag == "a" {
            skip = 1
            if Self.skipTags.contains(tag) && cls.split(whereSeparator: { $0.isWhitespace }).contains("subhead") {
                heading = ""
            }
            return
        }
        if tag == "p" {
            if cls.contains("psa-title") {
                inTitle = true
                title = ""
            } else if !cur.h.stripped.isEmpty {
                cur.h += "<br>"
            } else {
                cur.p = true
            }
            stack.append((tag, ""))
        } else if tag == "span" && cls == "red" {
            cur.h += "<span class=\"wj\">"
            stack.append((tag, "</span>"))
        } else if tag == "span" && (cls == "sc" || cls == "subhead-sc") {
            cur.h += "<span class=\"nd\">"
            stack.append((tag, "</span>"))
        } else if tag == "em" || tag == "i" {
            cur.h += "<i>"
            stack.append((tag, "</i>"))
        } else if tag == "br" {
            cur.h += "<br>"
        } else {
            stack.append((tag, ""))
        }
    }

    override func handleEndTag(_ tag: String) {
        guard let cur = cur else { return }
        if tag == "verse_export" {
            for (_, close) in stack.reversed() { cur.h += close }
            cur.h = cleanSpace(cur.h)
            self.cur = nil
            return
        }
        if skip > 0 {
            if headingNote == skip { headingNote = nil }
            skip -= 1
            if skip == 0, let h = heading {
                let text = spaces.sub(h, " ").stripped
                if !text.isEmpty {
                    cur.s = cur.s.map { "\($0)\n\(text)" } ?? text
                }
                heading = nil
            }
            return
        }
        if let (t, close) = stack.popLast() {
            cur.h += close
            if t == "p" && inTitle {
                inTitle = false
                if let title = title, !title.stripped.isEmpty {
                    cur.t = title.stripped
                }
            }
        }
    }

    override func handleData(_ data: String) {
        guard let cur = cur else { return }
        if skip > 0 {
            if heading != nil && headingNote == nil { heading! += data }
            return
        }
        if inTitle {
            title! += data
            return
        }
        cur.h += escapeHTML(data)
    }
}

// MARK: - API.Bible (NIV, CSB, NASB)

/// API.Bible's HTML uses USFM/USX style names.
///
///   <span class="v" data-sid="JHN 3:16">16</span>   verse marker
///   <p class="p|m|q1|q2|...">                       paragraphs and poetry lines
///   <p class="d|qa|sp|iex">                         psalm title, acrostic letter,
///                                                   speaker, textual note -> title
///   <p class="s|s1|s2...">                          section headings -> heading
///                                                   (CSB's Psalm 119 letters are s2
///                                                   headings holding a qac span;
///                                                   those become titles)
///   <p class="ms">                                  major heading -> heading (in the
///                                                   Psalms: book divisions and NASB
///                                                   psalm titles -> title)
///   <p class="r|cl...">                             other headings (dropped)
///   <span class="wj|nd|sc|add|it|qs">               red letters, LORD, italics
/// NASB puts psalm titles in "ms" blocks (next to "PSALM 23" labels, which are
/// dropped) and marks LORD as L<span class="sc">ord</span>.
/// Some texts carry junk from their print sources (CSB: "¥¥¥" dividers, "#" around
/// dashes, stray commas in <span class="sup">); those are removed.
final class USXParser: VerseHTMLParser {
    private static let titleBlocks: Set<String> = ["d", "qa", "sp", "iex"]
    private static let section = Re("s\\d*$")
    private static let headingRe = Re("(ms|mt|imt|is)\\d*$|r$|mr$|sr$|cl$|cd$|sd\\d*$")
    private static let italic: Set<String> = ["add", "it", "qs", "em", "bdit"]
    private static let sid = Re("(\\d+):(\\d+)")
    private static let psalmLabel = Re("\\s*psalm \\d+\\.?\\s*", ignoreCase: true)
    private static let hashDash = Re("\\s*#—\\s*#")
    private static let nbspDash = Re("\\u00a0+—")
    private static let junk = Re("¥+|#")

    private let psalms: Bool
    private var heading = false      // inside a heading block
    private var headingKeep = false  // ...that we keep (a section heading, psalm title or acrostic letter)
    private var kinds: [String] = [] // kind of each open span: "num", "nd" or "other"

    init(psalms: Bool = false) {
        self.psalms = psalms
    }

    override func handleStartTag(_ tag: String, _ attrs: Attrs) {
        let cls = classes(attrs)
        let c0 = cls.first ?? ""
        if skip > 0 {
            skip += 1
            return
        }
        if tag == "p" {
            if Self.titleBlocks.contains(c0) {
                startTitle()
            } else if c0 == "ms" {  // CSB major headings; NASB psalm titles, "BOOK ONE"
                heading = true
                headingKeep = true
                startTitle(psalms ? "t" : "s")
            } else if Self.section.match(c0) != nil {
                heading = true
                headingKeep = true
                startTitle("s")
            } else if Self.headingRe.match(c0) != nil {
                heading = true
                headingKeep = false
                startTitle()
            } else if c0 != "nb" {  // nb = "no break": continues the paragraph
                startBlock()
            }
        } else if tag == "span" {
            if cls.contains("sup") {  // CSB: stray footnote-position commas
                skip = 1
                return
            }
            if cls.contains("v") {
                if let m = Self.sid.search(Self.attr(attrs, "data-sid") ?? ""), title == nil {
                    startVerse(parseInt(m[1]!)!, parseInt(m[2]!)!)
                }
                kinds.append("num")
                return
            }
            kinds.append(cls.contains("nd") || cls.contains("sc") ? "nd" : "other")
            if cls.contains("qac") {
                headingKeep = true
                titleKind = "t"  // an acrostic letter is a title, not a heading
                plainSpan()
            } else if cls.contains("wj") {
                openSpan("<span class=\"wj\">", "</span>")
            } else if cls.contains("nd") || cls.contains("sc") {
                openSpan("<span class=\"nd\">", "</span>")
            } else if !Self.italic.isDisjoint(with: cls) {
                openSpan("<i>", "</i>")
            } else {
                plainSpan()
            }
        }
    }

    override func handleEndTag(_ tag: String) {
        if skip > 0 {
            skip -= 1
            return
        }
        if tag == "p", let t = title {
            if heading && !headingKeep {
                title = nil
            } else if Self.psalmLabel.fullMatch(t) != nil {
                title = nil  // NASB's "PSALM 23" label
            } else {
                endTitle()
            }
            heading = false
        } else if tag == "span", let kind = kinds.popLast() {
            if kind == "num" {
                inNum = false
            } else {
                closeSpan()
            }
        }
    }

    override func handleData(_ data: String) {
        // CSB typesetting codes: "¥¥¥" divider rows, and "\xa0#—\xa0#" around closed dashes
        var data = Self.hashDash.sub(data, "—")
        data = Self.nbspDash.sub(data, "—")
        data = Self.junk.sub(data, "")
        if kinds.contains("nd") && data.isUpper {
            data = data.components(separatedBy: " ").map(\.firstKeptRestLowered).joined(separator: " ")  // LORD -> Lord
        }
        text(data)
    }
}

// MARK: - NET (labs.bible.org JSON)

func parseNET(_ body: String) throws -> [Verse] {
    guard let data = body.data(using: .utf8),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw ProviderError("Passage not found in this translation.")
    }
    var verses: [Verse] = []
    for r in rows {
        let text = escapeHTML(r["text"] as? String ?? "")
        let title = (r["title"] as? String).map { !$0.isEmpty } ?? false
        guard let c = intValue(r["chapter"]), let v = intValue(r["verse"]) else { continue }
        verses.append(Verse(c: c, v: v, h: cleanSpace(text), p: title || verses.isEmpty))
    }
    return verses
}

private func intValue(_ x: Any?) -> Int? {
    if let n = x as? Int { return n }
    if let s = x as? String { return parseInt(s.stripped) }
    return nil
}
