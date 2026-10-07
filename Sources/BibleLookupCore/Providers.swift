import Foundation

// Where each translation's text comes from. Every provider turns a Ref into verses.

public struct ProviderError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

let userAgent = "BibleLookup-Mac/1.0 (personal use)"

func httpGet(_ url: String, headers: [String: String] = [:]) async throws -> String {
    guard let u = URL(string: url) else { throw ProviderError("Bad address: \(url)") }
    var req = URLRequest(url: u, timeoutInterval: 15)
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await URLSession.shared.data(for: req)
    } catch let e as URLError {
        throw ProviderError("Couldn’t reach the server (\(e.localizedDescription)).")
    }
    let body = String(decoding: data, as: UTF8.self)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 200
    switch code {
    case 200..<300: return body
    case 401, 403: throw ProviderError("The API key was rejected. Check it in Settings.")
    case 429: throw ProviderError("Rate limit reached for this translation. Try again later.")
    case 404: throw ProviderError("Passage not found in this translation.")
    default: throw ProviderError("HTTP \(code): \(body.prefix(300))")
    }
}

func query(_ params: [(String, String)]) -> String {
    var c = URLComponents()
    c.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
    // URLComponents leaves "+" alone; servers read it as a space
    return c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
}

/// Keep the verses inside the reference (some sources send more).
func within(_ ref: Ref, _ verses: [Verse]) throws -> [Verse] {
    let out = verses.filter { ref.contains($0.c, $0.v) && !$0.h.isEmpty }
    if out.isEmpty { throw ProviderError("Passage not found in this translation.") }
    return out
}

public struct Fetched: Sendable {
    public let verses: [Verse]
    public let copyright: String
    public var fums: [String] = []  // API.Bible view-report tokens
}

public protocol Provider: Sendable {
    var source: String { get }
    /// (true, nil) or (false, what to do about it)
    func available() -> (Bool, String?)
    func fetch(_ ref: Ref) async throws -> Fetched
}

/// Tell API.Bible's Fair Use Management System that these passages were shown.
/// Anonymous (a random device id and a per-launch session id). Failures are ignored.
/// https://docs.api.bible/guides/fair-use/
func reportFums(_ tokens: [String], deviceId: String, sessionId: String) async {
    let params = tokens.map { ("t", $0) } + [("dId", deviceId), ("sId", sessionId)]
    _ = try? await httpGet("https://fums.api.bible/f3?" + query(params))
}

// MARK: - bundled public-domain Bibles

/// A public-domain Bible bundled as JSON (built by python-reference/tools/build_usfm.py):
/// {"GEN": [ [ {"v": 1, "h": "...", "p": 1, "t": "..."}, ... ], ... ], ...}
public final class LocalBible: Provider, @unchecked Sendable {
    public let source = "Bundled (public domain)"
    let copyright: String
    let data: [String: [[[String: Any]]]]

    public init(json: Data, copyright: String) throws {
        guard let d = try JSONSerialization.jsonObject(with: json) as? [String: [[[String: Any]]]] else {
            throw ProviderError("Bundled Bible file is damaged.")
        }
        data = d
        self.copyright = copyright
    }

    public var verseCounts: [String: [Int]] { data.mapValues { $0.map(\.count) } }

    public func available() -> (Bool, String?) { (true, nil) }

    public func fetch(_ ref: Ref) async throws -> Fetched {
        let chapters = data[ref.book.id] ?? []
        var out: [Verse] = []
        for c in ref.c1...ref.c2 where c - 1 < chapters.count {
            for v in chapters[c - 1] {
                guard let n = v["v"] as? Int, ref.contains(c, n) else { continue }
                let p = (v["p"] as? Int ?? 0) != 0
                let t = (v["t"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                out.append(Verse(c: c, v: n, h: v["h"] as? String ?? "", p: p, t: t))
            }
        }
        return Fetched(verses: try within(ref, out), copyright: copyright)
    }
}

// MARK: - ESV

public struct ESV: Provider {
    public let source = "api.esv.org"
    static let copyright = "Scripture quotations are from the ESV® Bible (The Holy Bible, English Standard "
        + "Version®), © 2001 by Crossway, a publishing ministry of Good News Publishers. "
        + "Used by permission. All rights reserved."
    let key: String

    public func available() -> (Bool, String?) {
        key.isEmpty ? (false, "Add a free ESV API key (from api.esv.org) in Settings.") : (true, nil)
    }

    static let params: [(String, String)] = [
        ("include-passage-references", "false"),
        ("include-verse-numbers", "true"),
        ("include-first-verse-numbers", "true"),
        ("include-chapter-numbers", "true"),
        ("include-footnotes", "false"),
        ("include-footnote-body", "false"),
        ("include-headings", "true"),  // section headings and psalm titles
        ("include-subheadings", "true"),
        ("include-short-copyright", "false"),
        ("include-copyright", "false"),
        ("include-audio-link", "false"),
        ("include-book-titles", "false"),
        ("include-crossrefs", "false"),
        ("include-surrounding-chapters", "false"),
        ("include-selahs", "true"),
        ("wrapping-div", "false"),
        ("include-css-link", "false"),
        ("inline-styles", "false"),
    ]

    public func fetch(_ ref: Ref) async throws -> Fetched {
        var q = ref.query()
        if ref.isChapter && ref.book.chapters == 1 {
            // the ESV API reads "Jude 1" as Jude 1:1 in one-chapter books; ask for every
            // verse (one past the KJV count, for 3 John 1:15; the API stops at the last)
            q = "\(ref.book.name) 1:1-\(ref.book.verseCounts[0] + 1)"
        }
        let url = "https://api.esv.org/v3/passage/html/?" + query([("q", q)] + Self.params)
        let body = try await httpGet(url, headers: ["Authorization": "Token \(key)"])
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let passages = json?["passages"] as? [String] ?? []
        let p = ESVParser()
        p.feed(passages.joined(separator: "\n"))
        p.close()
        return Fetched(verses: try within(ref, p.result()), copyright: Self.copyright)
    }
}

// MARK: - NLT

public struct NLT: Provider {
    public let source = "api.nlt.to"
    static let copyright = "Scripture quotations are taken from the Holy Bible, New Living Translation, "
        + "copyright ©1996, 2004, 2015 by Tyndale House Foundation. Used by permission of "
        + "Tyndale House Publishers, Carol Stream, Illinois 60188. All rights reserved."
    let key: String

    init(key: String) {
        self.key = key.isEmpty ? "TEST" : key
    }

    public func available() -> (Bool, String?) { (true, nil) }

    public func fetch(_ ref: Ref) async throws -> Fetched {
        let page = try await httpGet("https://api.nlt.to/api/passages?"
            + query([("ref", ref.query()), ("version", "NLT"), ("key", key)]))
        let p = NLTParser()
        p.feed(page)
        return Fetched(verses: try within(ref, p.verses), copyright: Self.copyright)
    }
}

// MARK: - NET

public struct NET: Provider {
    public let source = "labs.bible.org"
    static let copyright = "Scripture quoted by permission. Quotations designated (NET) are from the NET Bible® "
        + "copyright ©1996, 2019 by Biblical Studies Press, L.L.C. http://netbible.com "
        + "All rights reserved."

    public func available() -> (Bool, String?) { (true, nil) }

    public func fetch(_ ref: Ref) async throws -> Fetched {
        let body = try await httpGet("https://labs.bible.org/api/?"
            + query([("passage", ref.query()), ("type", "json"), ("formatting", "plain")]))
        // labs.bible.org answers a missing verse with the whole chapter; filter it
        return Fetched(verses: try within(ref, try parseNET(body)), copyright: Self.copyright)
    }
}

// MARK: - API.Bible

public struct APIBible: Provider {
    public let source = "API.Bible"
    let key: String
    let bibleId: String

    public func available() -> (Bool, String?) {
        if key.isEmpty { return (false, "Add an API.Bible key in Settings.") }
        if bibleId.isEmpty {
            return (false, "Not on your API.Bible plan. Choose it in your API.Bible dashboard, then click Find My Translations in Settings.")
        }
        return (true, nil)
    }

    static let params: [(String, String)] = [
        ("content-type", "html"),
        ("include-notes", "false"),
        ("include-titles", "true"),  // psalm titles etc.
        ("include-chapter-numbers", "false"),
        ("include-verse-numbers", "true"),
        ("include-verse-spans", "false"),
    ]

    private func get(_ path: String, psalms: Bool, copyright: inout String, tokens: inout [String]) async throws -> [Verse] {
        let url = "https://rest.api.bible/v1/bibles/\(bibleId)/\(path)?" + query(Self.params)
        let body = try await httpGet(url, headers: ["api-key": key])
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let data = json["data"] as? [String: Any] ?? [:]
        if let c = data["copyright"] as? String, !c.isEmpty {
            copyright = cleanWhitespace(c)
        }
        let p = USXParser(psalms: psalms)
        p.feed(data["content"] as? String ?? "")
        p.close()
        if let t = (json["meta"] as? [String: Any])?["fumsToken"] as? String, !t.isEmpty {
            tokens.append(t)
        }
        return p.result()
    }

    public func fetch(_ ref: Ref) async throws -> Fetched {
        let b = ref.book
        let psalms = b.id == "PSA"
        var verses: [Verse] = []
        var tokens: [String] = []
        var copyright = ""
        if ref.isChapter {
            for c in ref.c1...ref.c2 {
                verses += try await get("chapters/\(b.id).\(c)", psalms: psalms, copyright: &copyright, tokens: &tokens)
            }
        } else {
            let v1 = ref.v1!, v2 = ref.v2!
            do {
                verses = try await get("passages/\(b.id).\(ref.c1).\(v1)-\(b.id).\(ref.c2).\(v2)",
                                       psalms: psalms, copyright: &copyright, tokens: &tokens)
            } catch let e as ProviderError {
                if v2 <= b.verseCounts[ref.c2 - 1] { throw e }
                // the extra-verse allowance overshot this translation; retry without it
                verses = try await get("passages/\(b.id).\(ref.c1).\(v1)-\(b.id).\(ref.c2).\(v2 - 1)",
                                       psalms: psalms, copyright: &copyright, tokens: &tokens)
            }
        }
        return Fetched(verses: try within(ref, verses), copyright: copyright, fums: tokens)
    }
}

private let whitespaceRuns = Re("\\s+")

func cleanWhitespace(_ s: String) -> String {
    whitespaceRuns.sub(s, " ").stripped
}

// MARK: - finding API.Bible translation IDs (the Python version's --setup)

public struct FoundBible: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
}

let apiBibleMatch: [(String, Set<String>)] = [
    ("NIV", ["NIV", "NIV11", "NIV2011"]),
    ("CSB", ["CSB", "CSB17"]),
    ("NASB", ["NASB", "NASB95", "NASB1995", "NASB20", "NASB2020"]),
]

/// Which of NIV, CSB and NASB this API.Bible key can read. Returns (matches, how many English Bibles the key can read).
public func findAPIBibles(key: String) async throws -> ([String: FoundBible], Int) {
    let body = try await httpGet("https://rest.api.bible/v1/bibles?language=eng", headers: ["api-key": key])
    let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    let bibles = json?["data"] as? [[String: Any]] ?? []
    var found: [String: FoundBible] = [:]
    for b in bibles {
        let abbrs = Set(["abbreviation", "abbreviationLocal"].map { k in
            String((b[k] as? String ?? "").filter { $0.isLetter || $0.isNumber }).uppercased()
        })
        for (tid, names) in apiBibleMatch where !abbrs.isDisjoint(with: names) && found[tid] == nil {
            let name = (b["nameLocal"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? b["name"] as? String ?? tid
            found[tid] = FoundBible(id: b["id"] as? String ?? "", name: name)
        }
    }
    return (found, bibles.count)
}
