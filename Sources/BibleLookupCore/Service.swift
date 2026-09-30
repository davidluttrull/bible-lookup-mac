import Foundation

// The answers to the web page's /api requests (the Python version's server.py).

public struct Translation: Sendable {
    public let id: String
    public let name: String
    let logos: String?  // resource name for "Open in Logos" links (nil = not in Logos)
    let bg: String      // BibleGateway version code for the fallback link
}

/// Order here is the order in the translation picker.
public let translations: [Translation] = [
    Translation(id: "NIV", name: "New International Version", logos: "niv2011", bg: "NIV"),
    Translation(id: "ESV", name: "English Standard Version", logos: "esv", bg: "ESV"),
    Translation(id: "KJV", name: "King James Version", logos: "kjv", bg: "KJV"),
    Translation(id: "NLT", name: "New Living Translation", logos: "nlt", bg: "NLT"),
    Translation(id: "CSB", name: "Christian Standard Bible", logos: "csb", bg: "CSB"),
    Translation(id: "NASB", name: "New American Standard Bible (1995)", logos: "nasb95", bg: "NASB1995"),
    Translation(id: "NET", name: "New English Translation", logos: "gs-netbible", bg: "NET"),
    Translation(id: "ASV", name: "American Standard Version", logos: "asv", bg: "ASV"),
]
public let apiBibleIds = ["NIV", "CSB", "NASB"]
let defaultTranslation = "KJV"

/// Keys and API.Bible translation IDs (kept by the app in the keychain and preferences).
public struct Config: Sendable, Equatable {
    public var esvKey = ""
    public var nltKey = ""
    public var apiBibleKey = ""
    public var apiBible: [String: FoundBible] = [:]
    public var fumsDeviceId = ""

    public init(esvKey: String = "", nltKey: String = "", apiBibleKey: String = "",
                apiBible: [String: FoundBible] = [:], fumsDeviceId: String = "") {
        self.esvKey = esvKey
        self.nltKey = nltKey
        self.apiBibleKey = apiBibleKey
        self.apiBible = apiBible
        self.fumsDeviceId = fumsDeviceId
    }
}

public struct APIResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public final class BibleService: @unchecked Sendable {
    public let bible: Bible
    private let bundled: [String: LocalBible]
    private let lock = NSLock()
    private var providers: [String: Provider] = [:]
    private var config = Config()
    private var cache: [CacheKey: (result: [String: Any], fums: [String])] = [:]
    private var cacheOrder: [CacheKey] = []
    private let fumsSession = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    private struct CacheKey: Hashable {
        let tid: String
        let ref: Ref
    }

    /// kjv/asv: the bundled public-domain JSON files.
    public init(kjv: Data, asv: Data, config: Config) throws {
        let k = try LocalBible(json: kjv, copyright: "King James Version. Public domain.")
        let a = try LocalBible(json: asv, copyright: "American Standard Version (1901). Public domain.")
        bundled = ["KJV": k, "ASV": a]
        // KJV verse counts are the reference for parsing and validation
        bible = Bible(verseCounts: k.verseCounts)
        update(config)
    }

    /// New keys or translation IDs: rebuild the online providers and forget cached passages.
    public func update(_ cfg: Config) {
        var p: [String: Provider] = [:]
        for t in translations {
            switch t.id {
            case "KJV", "ASV": p[t.id] = bundled[t.id]!
            case "ESV": p[t.id] = ESV(key: cfg.esvKey)
            case "NLT": p[t.id] = NLT(key: cfg.nltKey)
            case "NET": p[t.id] = NET()
            default: p[t.id] = APIBible(key: cfg.apiBibleKey, bibleId: cfg.apiBible[t.id]?.id ?? "")
            }
        }
        locked {
            providers = p
            config = cfg
            cache = [:]
            cacheOrder = []
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func provider(_ tid: String) -> Provider? {
        locked { providers[tid] }
    }

    private func reportViews(_ tokens: [String]) {
        guard !tokens.isEmpty else { return }
        let device = locked { config.fumsDeviceId }
        guard !device.isEmpty else { return }
        let session = fumsSession
        Task.detached { await reportFums(tokens, deviceId: device, sessionId: session) }
    }

    // MARK: - /api/config

    public func configPayload() -> [String: Any] {
        let list: [[String: Any]] = translations.map { t in
            let p = provider(t.id)!
            let (ok, reason) = p.available()
            return ["id": t.id, "name": t.name, "available": ok, "reason": reason ?? NSNull(),
                    "source": p.source, "inLogos": t.logos != nil]
        }
        let books: [[String: Any]] = bible.books.map { ["id": $0.id, "name": $0.name, "chapters": $0.chapters] }
        return ["translations": list, "books": books, "default": defaultTranslation]
    }

    // MARK: - payload pieces

    public func links(_ t: Translation, _ ref: Ref) -> [String: Any] {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "_.-~/")
        let q = ref.query().addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return [
            "logos": t.logos.map { "logosres:\($0);ref=Bible.\(ref.logos())" } ?? NSNull(),
            "bibleGateway": "https://www.biblegateway.com/passage/?search=\(q)&version=\(t.bg)",
        ]
    }

    public func refPayload(_ ref: Ref) -> [String: Any] {
        let b = ref.book
        let books = bible.books
        let name = b.id == "PSA" && ref.c1 == ref.c2 ? "Psalm" : b.name
        var prev: (Book, Int)? = nil
        if ref.c1 > 1 { prev = (b, ref.c1 - 1) } else if b.index > 0 { prev = (books[b.index - 1], books[b.index - 1].chapters) }
        var next: (Book, Int)? = nil
        if ref.c2 < b.chapters { next = (b, ref.c2 + 1) } else if b.index + 1 < books.count { next = (books[b.index + 1], 1) }
        func label(_ x: (Book, Int)?) -> Any {
            guard let (bk, c) = x else { return NSNull() }
            return "\(bk.name) \(c)".replacingOccurrences(of: "Psalms", with: "Psalm")
        }
        return [
            "book": b.id, "bookName": b.name, "c1": ref.c1, "v1": ref.v1 ?? NSNull(), "c2": ref.c2,
            "v2": ref.v2 ?? NSNull(), "isChapter": ref.isChapter, "query": ref.query(),
            "display": ref.query(name).replacingOccurrences(of: "-", with: "–"),
            "chapterQuery": "\(name) \(ref.c1)", "prev": label(prev), "next": label(next),
        ]
    }

    // MARK: - /api/passage

    public func passage(_ q: String?, _ tid: String?) async throws -> (Int, [String: Any]) {
        let ref = try bible.parse(q)  // throws RefError
        let id = (tid ?? "").uppercased()
        guard let t = translations.first(where: { $0.id == id }), let p = provider(id) else {
            throw RefError("Unknown translation “\(tid ?? "")”.")
        }
        var base: [String: Any] = ["ref": refPayload(ref), "translation": t.id, "translationName": t.name]
        base.merge(links(t, ref)) { a, _ in a }
        let (ok, reason) = p.available()
        if !ok {
            base["unavailable"] = reason
            base["settings"] = true  // the page offers an "Open Settings" button
            return (200, base)
        }
        let key = CacheKey(tid: t.id, ref: ref)
        let hit: (result: [String: Any], fums: [String])? = locked {
            guard let hit = cache[key] else { return nil }
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            return hit
        }
        if let hit = hit {
            reportViews(hit.fums)
            return (200, hit.result)
        }
        let fetched: Fetched
        do {
            fetched = try await p.fetch(ref)
        } catch let e as ProviderError {
            base["error"] = e.message
            if e.message.contains("Settings") { base["settings"] = true }
            return (502, base)
        }
        var result = base
        result["verses"] = fetched.verses.map(\.json)
        result["copyright"] = fetched.copyright
        result["source"] = p.source
        locked {
            if cache[key] == nil { cacheOrder.append(key) }
            cache[key] = (result, fetched.fums)
            while cacheOrder.count > 500 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        }
        reportViews(fetched.fums)
        return (200, result)
    }

    // MARK: - /api/parse

    public func parsePayload(_ q: String?) -> (Int, [String: Any]) {
        var parts: [[String: Any]] = []
        for (text, r) in bible.split(q) {
            switch r {
            case .failure(let e):
                parts.append(["input": text, "error": e.message])
            case .success(let ref):
                let name = ref.book.id == "PSA" && ref.c1 == ref.c2 ? "Psalm" : nil
                parts.append(["input": text, "query": ref.query(name)])
            }
        }
        if parts.isEmpty { return (400, ["error": "Type a reference, like John 3:16."]) }
        return (200, ["parts": parts])
    }

    // MARK: - one entry point for the web view

    /// Answer a request for /api/<path>?<query> with (status, JSON).
    public func handle(path: String, query: [String: String]) async -> APIResponse {
        var status = 200
        var obj: [String: Any]
        switch path {
        case "/api/config":
            obj = configPayload()
        case "/api/parse":
            (status, obj) = parsePayload(query["q"] ?? "")
        case "/api/passage":
            do {
                (status, obj) = try await passage(query["q"] ?? "", query["t"] ?? defaultTranslation)
            } catch let e as RefError {
                (status, obj) = (400, ["error": e.message])
            } catch {
                (status, obj) = (500, ["error": "\(error)"])
            }
        default:
            (status, obj) = (404, ["error": "not found"])
        }
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return APIResponse(status: status, body: body)
    }
}
