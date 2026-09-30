import Foundation

// Bible book table and reference parsing ("jn 3:16-18" -> Ref).

/// (USFM id, display name, Logos abbreviation, extra aliases)
let bookTable: [(String, String, String, String)] = [
    ("GEN", "Genesis", "Ge", "gen ge gn"),
    ("EXO", "Exodus", "Ex", "exo ex exod"),
    ("LEV", "Leviticus", "Le", "lev le lv"),
    ("NUM", "Numbers", "Nu", "num nu nm nb"),
    ("DEU", "Deuteronomy", "Dt", "deut deu de dt"),
    ("JOS", "Joshua", "Jos", "josh jos jsh"),
    ("JDG", "Judges", "Jdg", "judg jdg jg jdgs"),
    ("RUT", "Ruth", "Ru", "rth ru rut"),
    ("1SA", "1 Samuel", "1Sa", "1sam 1sa 1sm 1s"),
    ("2SA", "2 Samuel", "2Sa", "2sam 2sa 2sm 2s"),
    ("1KI", "1 Kings", "1Ki", "1kgs 1ki 1kg 1k"),
    ("2KI", "2 Kings", "2Ki", "2kgs 2ki 2kg 2k"),
    ("1CH", "1 Chronicles", "1Ch", "1chr 1ch 1chron"),
    ("2CH", "2 Chronicles", "2Ch", "2chr 2ch 2chron"),
    ("EZR", "Ezra", "Ezr", "ezr"),
    ("NEH", "Nehemiah", "Ne", "neh ne"),
    ("EST", "Esther", "Es", "esth est es"),
    ("JOB", "Job", "Job", "jb"),
    ("PSA", "Psalms", "Ps", "ps psa psalm pss psm pslm"),
    ("PRO", "Proverbs", "Pr", "prov pro pr prv"),
    ("ECC", "Ecclesiastes", "Ec", "eccl ecc ec eccles qoh"),
    ("SNG", "Song of Songs", "So", "song sng sos ss songofsolomon canticles cant"),
    ("ISA", "Isaiah", "Is", "isa is"),
    ("JER", "Jeremiah", "Je", "jer je jr"),
    ("LAM", "Lamentations", "La", "lam la"),
    ("EZK", "Ezekiel", "Eze", "ezek eze ezk"),
    ("DAN", "Daniel", "Da", "dan da dn"),
    ("HOS", "Hosea", "Ho", "hos ho"),
    ("JOL", "Joel", "Joe", "joe jl"),
    ("AMO", "Amos", "Am", "am amo"),
    ("OBA", "Obadiah", "Ob", "obad ob oba"),
    ("JON", "Jonah", "Jon", "jon jnh"),
    ("MIC", "Micah", "Mic", "mic mc"),
    ("NAM", "Nahum", "Na", "nah na"),
    ("HAB", "Habakkuk", "Hab", "hab hb"),
    ("ZEP", "Zephaniah", "Zep", "zeph zep zp"),
    ("HAG", "Haggai", "Hag", "hag hg"),
    ("ZEC", "Zechariah", "Zec", "zech zec zc"),
    ("MAL", "Malachi", "Mal", "mal ml"),
    ("MAT", "Matthew", "Mt", "matt mat mt"),
    ("MRK", "Mark", "Mk", "mrk mar mk mr"),
    ("LUK", "Luke", "Lk", "luk lk lu"),
    ("JHN", "John", "Jn", "joh jhn jn"),
    ("ACT", "Acts", "Ac", "act ac"),
    ("ROM", "Romans", "Ro", "rom ro rm"),
    ("1CO", "1 Corinthians", "1Co", "1cor 1co"),
    ("2CO", "2 Corinthians", "2Co", "2cor 2co"),
    ("GAL", "Galatians", "Ga", "gal ga"),
    ("EPH", "Ephesians", "Eph", "eph ephes"),
    ("PHP", "Philippians", "Php", "phil php pp"),
    ("COL", "Colossians", "Col", "col"),
    ("1TH", "1 Thessalonians", "1Th", "1thess 1thes 1th"),
    ("2TH", "2 Thessalonians", "2Th", "2thess 2thes 2th"),
    ("1TI", "1 Timothy", "1Ti", "1tim 1ti 1tm"),
    ("2TI", "2 Timothy", "2Ti", "2tim 2ti 2tm"),
    ("TIT", "Titus", "Tt", "tit ti"),
    ("PHM", "Philemon", "Phm", "philem phm phlm phile"),
    ("HEB", "Hebrews", "Heb", "heb"),
    ("JAS", "James", "Jas", "jas jm jam"),
    ("1PE", "1 Peter", "1Pe", "1pet 1pe 1pt 1p"),
    ("2PE", "2 Peter", "2Pe", "2pet 2pe 2pt 2p"),
    ("1JN", "1 John", "1Jn", "1jn 1jo 1joh 1jhn 1j"),
    ("2JN", "2 John", "2Jn", "2jn 2jo 2joh 2jhn 2j"),
    ("3JN", "3 John", "3Jn", "3jn 3jo 3joh 3jhn 3j"),
    ("JUD", "Jude", "Jud", "jud jd"),
    ("REV", "Revelation", "Re", "rev re rv revelations apocalypse"),
]

public final class Book: Hashable, @unchecked Sendable {
    public let id: String
    public let name: String
    let logos: String
    let index: Int
    let verseCounts: [Int]  // verses per chapter (KJV versification)

    init(id: String, name: String, logos: String, index: Int, verseCounts: [Int]) {
        self.id = id
        self.name = name
        self.logos = logos
        self.index = index
        self.verseCounts = verseCounts
    }

    public var chapters: Int { verseCounts.count }

    public static func == (a: Book, b: Book) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public struct Ref: Hashable, Sendable {
    public let book: Book
    public let c1: Int
    public let v1: Int?  // nil = whole chapter(s)
    public let c2: Int
    public let v2: Int?

    public var isChapter: Bool { v1 == nil }

    public func contains(_ c: Int, _ v: Int) -> Bool {
        let start = (c1, v1 ?? 1)
        let end = (c2, v2 ?? 1_000_000)
        return start <= (c, v) && (c, v) <= end
    }

    /// Plain reference string, e.g. "John 3:16-18", "John 3:36-4:2", "John 3".
    public func query(_ name: String? = nil) -> String {
        let name = name ?? book.name
        guard let v1 = v1 else {
            return "\(name) \(c1)" + (c2 != c1 ? "-\(c2)" : "")
        }
        var s = "\(name) \(c1):\(v1)"
        if c2 != c1 {
            s += "-\(c2):\(v2!)"
        } else if v2 != v1 {
            s += "-\(v2!)"
        }
        return s
    }

    /// Logos reference, e.g. "Jn3.16-18".
    public func logos() -> String {
        let b = book.logos
        guard let v1 = v1 else {
            return "\(b)\(c1)" + (c2 != c1 ? "-\(c2)" : "")
        }
        var s = "\(b)\(c1).\(v1)"
        if c2 != c1 {
            s += "-\(c2).\(v2!)"
        } else if v2 != v1 {
            s += "-\(v2!)"
        }
        return s
    }
}

public struct RefError: Error, CustomStringConvertible {
    public let message: String
    init(_ message: String) { self.message = message }
    public var description: String { message }
}

private let nonAlnum = Re("[^a-z0-9]")

private func norm(_ s: String) -> String {
    nonAlnum.sub(s.lowercased(), "")
}

private let ordinals: [(Re, String)] = [
    (Re("^(?:iii|third|3rd)[\\s.]+", ignoreCase: true), "3"),
    (Re("^(?:ii|second|2nd)[\\s.]+", ignoreCase: true), "2"),
    (Re("^(?:i|first|1st)[\\s.]+", ignoreCase: true), "1"),
]

private let numsRe = Re(
    "(\\d+)(?:\\s*[:.]\\s*(\\d+)|\\s+(\\d+))?"            // chapter, optional :verse (or "3 16")
    + "(?:\\s*[-‐-―]\\s*(\\d+)(?:\\s*[:.]\\s*(\\d+))?)?"  // optional -end
)
private let refRe = Re("^(.*?[a-zA-Z].*?)\\s*(\\d[\\d\\s:.\\-‐-―]*)?$")

/// Book lookup + reference parsing, using KJV verse counts for validation.
public final class Bible: @unchecked Sendable {
    public let books: [Book]
    let byId: [String: Book]
    private var alias: [String: Book] = [:]

    public init(verseCounts: [String: [Int]]) {
        var books: [Book] = []
        var byId: [String: Book] = [:]
        for (i, (bid, name, logos, aliases)) in bookTable.enumerated() {
            let book = Book(id: bid, name: name, logos: logos, index: i, verseCounts: verseCounts[bid] ?? [])
            books.append(book)
            byId[bid] = book
            for a in [name, bid] + aliases.split(separator: " ").map(String.init) {
                let key = norm(a)
                if alias[key] == nil { alias[key] = book }
            }
        }
        self.books = books
        self.byId = byId
    }

    public func findBook(_ text: String) -> Book? {
        var t = text.stripped
        for (pat, num) in ordinals {
            t = pat.sub(t, num)
        }
        let key = norm(t)
        if key.isEmpty { return nil }
        if let b = alias[key] { return b }
        return books.first { norm($0.name).hasPrefix(key) }  // unique-enough prefix, canonical order wins
    }

    public func parse(_ input: String?) throws -> Ref {
        let q = (input ?? "").stripped
        if q.isEmpty {
            throw RefError("Type a reference, like John 3:16.")
        }
        guard let m = refRe.match(q) else {
            throw RefError("Couldn’t understand “\(q)”. Try something like John 3:16.")
        }
        guard let book = findBook(m[1]!) else {
            throw RefError("Couldn’t find a book called “\(m[1]!.stripped)”.")
        }
        var nums = (m[2] ?? "").stripped
        while let last = nums.last, ":.-".contains(last) { nums.removeLast() }
        if nums.isEmpty {
            return try make(book, 1, nil, 1, nil)
        }
        guard let n = numsRe.fullMatch(nums) else {
            throw RefError("Couldn’t understand “\(nums)”. Try something like \(book.name) 3:16.")
        }
        let c1 = parseInt(n[1]!)!
        let v1 = (n[2] ?? n[3]).flatMap(parseInt)
        let x = n[4].flatMap(parseInt)
        let y = n[5].flatMap(parseInt)

        if book.chapters == 1 && v1 == nil && y == nil && !(c1 == 1 && x == nil) {
            // "Jude 5" / "Jude 3-5" mean verses in single-chapter books
            return try make(book, 1, c1, 1, x ?? c1)
        }
        guard let v1 = v1 else {
            guard let x = x else { return try make(book, c1, nil, c1, nil) }
            guard let y = y else { return try make(book, c1, nil, x, nil) }
            return try make(book, c1, 1, x, y)
        }
        guard let x = x else { return try make(book, c1, v1, c1, v1) }
        guard let y = y else { return try make(book, c1, v1, c1, x) }
        return try make(book, c1, v1, x, y)
    }

    /// Parse "James 1:5; John 3:16-18" into [(text, Ref or RefError)].
    ///
    /// A part with no book name continues the previous book, so
    /// "John 3:16; 4:2" means John 3:16 and John 4:2.
    public func split(_ q: String?, limit: Int = 12) -> [(String, Result<Ref, RefError>)] {
        var out: [(String, Result<Ref, RefError>)] = []
        var prev: Ref? = nil
        let parts = (q ?? "").components(separatedBy: ";").map(\.stripped).filter { !$0.isEmpty }.prefix(limit)
        for part in parts {
            let ref: Ref
            do {
                ref = try parse(part)
            } catch let e as RefError {
                guard let p = prev, part.first?.wholeNumberValue != nil else {  // Python: part[0].isdigit()
                    out.append((part, .failure(e)))
                    continue
                }
                do {
                    ref = try parse("\(p.book.name) \(part)")
                } catch let e2 as RefError {
                    out.append((part, .failure(e2)))
                    continue
                } catch { continue }
            } catch { continue }
            out.append((part, .success(ref)))
            prev = ref
        }
        return out
    }

    private func make(_ book: Book, _ c1: Int, _ v1: Int?, _ c2: Int, _ v2: Int?) throws -> Ref {
        func checkCh(_ c: Int) throws {
            if !(1...max(book.chapters, 1)).contains(c) || book.chapters == 0 {
                throw RefError("\(book.name) has only \(book.chapters) chapter\(book.chapters > 1 ? "s" : "").")
            }
        }
        try checkCh(c1)
        try checkCh(c2)
        if c2 < c1 {
            throw RefError("The end of the range comes before the start.")
        }
        var v2 = v2
        if let v1 = v1 {
            // allow one extra verse: some modern translations number one more
            // verse than the KJV (e.g. 3 John 1:15, Revelation 12:18)
            let limit = book.verseCounts[c1 - 1] + 1
            if !(1...limit).contains(v1) {
                throw RefError("\(book.name) \(c1) has only \(limit - 1) verses.")
            }
            if c2 == c1 && v2! < v1 {
                throw RefError("The end of the range comes before the start.")
            }
            v2 = min(v2!, book.verseCounts[c2 - 1] + 1)
        }
        return Ref(book: book, c1: c1, v1: v1, c2: c2, v2: v2)
    }
}
