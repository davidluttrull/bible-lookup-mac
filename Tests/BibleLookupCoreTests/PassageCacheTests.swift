import XCTest
@testable import BibleLookupCore

// The same checks as python-reference/tests/test_passage_cache.py, plus how the app's
// service uses the cache.
final class PassageCacheTests: XCTestCase {
    let bible = sharedService.bible
    var dir: URL!
    var path: URL!
    var cache: PassageCache!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bl-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("cache.db")
        cache = PassageCache(path: path)
    }

    override func tearDownWithError() throws {
        cache = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func result(_ ref: Ref) -> [String: Any] {
        var verses: [[String: Any]] = []
        for c in ref.c1...ref.c2 {
            for v in 1...ref.book.verseCounts[c - 1] where ref.contains(c, v) {
                verses.append(["c": c, "v": v, "h": "x", "p": false])
            }
        }
        return ["verses": verses]
    }

    @discardableResult
    func put(_ q: String, _ tid: String = "ESV", fums: [String] = [], into c: PassageCache? = nil) throws -> Ref {
        let ref = try bible.parse(q)
        (c ?? cache).put(tid, ref, result(ref), fums)
        return ref
    }

    func cached(_ q: String, _ tid: String = "ESV", in c: PassageCache? = nil) throws -> Bool {
        (c ?? cache).get(tid, try bible.parse(q)) != nil
    }

    func testHitAndFums() throws {
        try put("John 3:16", "NIV", fums: ["tok"])
        XCTAssertEqual(cache.get("NIV", try bible.parse("John 3:16"))?.fums, ["tok"])
        XCTAssertFalse(try cached("John 3:16", "ESV"))
    }

    func testESVTotalLimit() throws {
        // Psalm chapters, oldest first; keep adding past 500 verses
        for c in 1..<60 { try put("Ps \(c)") }
        XCTAssertLessThanOrEqual(cache.stats()["ESV"]!.verses, PassageCache.maxVerses)
        XCTAssertTrue(try cached("Ps 59"))
        XCTAssertFalse(try cached("Ps 1"))  // least recently used went first
    }

    func testLRUOrder() throws {
        for c in 1..<25 { try put("Ps \(c)") }
        XCTAssertTrue(try cached("Ps 1"))  // shown again, so now the newest
        for c in 25..<40 { try put("Ps \(c)") }
        XCTAssertTrue(try cached("Ps 1"))
        XCTAssertFalse(try cached("Ps 2"))
    }

    func testOtherTranslationsUnlimited() throws {
        for tid in ["NIV", "CSB", "NLT", "NET"] {
            for c in 1..<60 { try put("Ps \(c)", tid) }
            try put("Jude 1", tid)  // a whole book is fine too
            XCTAssertEqual(cache.stats()[tid]?.passages, 60)
            XCTAssertTrue(try cached("Ps 1", tid) && cached("Jude 1", tid))
        }
    }

    func testHalfBookLimit() throws {
        try put("Jude 1")  // 25 verses: more than half of Jude
        XCTAssertFalse(try cached("Jude 1"))
        try put("Jude 1:1-8")
        try put("Jude 1:9-14")  // 8 + 6 > 12: the first is dropped
        XCTAssertFalse(try cached("Jude 1:1-8"))
        XCTAssertTrue(try cached("Jude 1:9-14"))
        try put("John 3")  // other books are untouched
        try put("Jude 1", "NIV")  // and other translations aren't limited
        XCTAssertTrue(try cached("Jude 1:9-14"))
    }

    func testSurvivesRestart() throws {
        try put("Lev 16:1-19", "NLT")
        let again = PassageCache(path: path)
        XCTAssertTrue(try cached("Lev 16:1-19", "NLT", in: again))
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testExpiry() throws {
        let expiring = PassageCache(path: dir.appendingPathComponent("expiring.db"), maxAgeDays: 30)
        try put("John 3:16", into: expiring)
        try put("John 3:17", "NIV", into: expiring)
        expiring.setFetchTime(Date().timeIntervalSince1970 - 31 * 86400)
        XCTAssertFalse(try cached("John 3:16", in: expiring))
        XCTAssertFalse(try cached("John 3:17", "NIV", in: expiring))
    }

    func testNoExpiry() throws {
        let forever = PassageCache(path: dir.appendingPathComponent("forever.db"))  // the default
        try put("John 3:16", "NIV", into: forever)
        forever.setFetchTime(0)
        XCTAssertTrue(try cached("John 3:16", "NIV", in: forever))
    }

    // MARK: - the app's service

    func service(_ config: Config) throws -> BibleService {
        let data = repoRoot.appendingPathComponent("Resources/Data")
        return try BibleService(kjv: Data(contentsOf: data.appendingPathComponent("kjv.json")),
                                asv: Data(contentsOf: data.appendingPathComponent("asv.json")),
                                config: config, cachePath: path)
    }

    func testLaunchKeepsCache() throws {
        try put("John 3:16", "NIV")
        try put("John 3:16", "ESV")
        cache = nil
        let cfg = Config(apiBibleKey: "k", apiBible: ["NIV": FoundBible(id: "niv-id", name: "NIV")])
        _ = try service(cfg)  // the app starting up
        XCTAssertTrue(try cached("John 3:16", "NIV", in: PassageCache(path: path)))
        XCTAssertTrue(try cached("John 3:16", "ESV", in: PassageCache(path: path)))
    }

    func testEditionChangeClearsOnlyThatTranslation() throws {
        let cfg = Config(apiBibleKey: "k", apiBible: ["NIV": FoundBible(id: "niv-id", name: "NIV"),
                                                       "NASB": FoundBible(id: "nasb95", name: "NASB 1995")])
        let svc = try service(cfg)
        try put("John 3:16", "NIV")
        try put("John 3:16", "NASB")
        try put("John 3:16", "ESV")
        var newer = cfg
        newer.apiBible["NASB"] = FoundBible(id: "nasb2020", name: "NASB 2020")
        newer.esvKey = "another key"  // a new key alone doesn't change the text
        svc.update(newer)
        XCTAssertTrue(try cached("John 3:16", "NIV"))
        XCTAssertFalse(try cached("John 3:16", "NASB"))
        XCTAssertTrue(try cached("John 3:16", "ESV"))
    }

    func testBundledBiblesNotCached() async throws {
        let svc = try service(Config())
        let (status, _) = try await svc.passage("John 3:16", "KJV")
        XCTAssertEqual(status, 200)
        XCTAssertNil(cache.stats()["KJV"])
    }
}
