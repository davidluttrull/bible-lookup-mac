import XCTest
@testable import BibleLookupCore

// The Swift port must give the same answers as the Python version it replaced.
// Fixtures/ holds real responses from each source and the Python version's output for
// them (recorded by python-reference/tools/make_fixtures.py).

let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func loadJSON(_ name: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent(name)))
}

func sameJSON(_ a: Any, _ b: Any) -> Bool {
    NSArray(array: [a]).isEqual(to: [b])
}

let sharedService: BibleService = {
    let data = repoRoot.appendingPathComponent("Resources/Data")
    return try! BibleService(kjv: Data(contentsOf: data.appendingPathComponent("kjv.json")),
                             asv: Data(contentsOf: data.appendingPathComponent("asv.json")),
                             config: Config())
}()

final class ParserTests: XCTestCase {
    func testEveryRecordedResponse() throws {
        // Recorded from the copyrighted translations, so not in the public repository;
        // python-reference/tools/make_fixtures.py records them with your own keys.
        guard FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("parsers.json").path) else {
            throw XCTSkip("No recorded source responses (run python3 python-reference/tools/make_fixtures.py)")
        }
        let cases = try loadJSON("parsers.json") as! [[String: Any]]
        XCTAssertGreaterThan(cases.count, 80)
        var bySource: [String: Int] = [:]
        for c in cases {
            let source = c["source"] as! String
            let file = c["file"] as! String
            let raw = try String(contentsOf: fixtures.appendingPathComponent("sources/\(file)"), encoding: .utf8)
            let got: [Verse]
            switch source {
            case "esv":
                let p = ESVParser()
                p.feed(raw)
                got = p.result()
            case "nlt":
                let p = NLTParser()
                p.feed(raw)
                got = p.verses
            case "net":
                got = try parseNET(raw)
            default:
                let p = USXParser(psalms: c["psalms"] as? Bool ?? false)
                p.feed(raw)
                got = p.result()
            }
            let expected = c["expected"] as! [[String: Any]]
            bySource[source, default: 0] += 1
            XCTAssertEqual(got.count, expected.count, "\(file): verse count")
            for (g, e) in zip(got, expected) where !sameJSON(g.json, e) {
                XCTFail("\(file) \(g.c):\(g.v)\n  swift:  \(g.json)\n  python: \(e)")
                break
            }
        }
        // every source was exercised
        for s in ["esv", "nlt", "net", "niv", "csb", "nasb"] {
            XCTAssertGreaterThan(bySource[s] ?? 0, 10, s)
        }
    }
}

final class RefTests: XCTestCase {
    let bible = sharedService.bible

    func testParse() throws {
        let fx = try loadJSON("refs.json") as! [String: Any]
        for c in fx["parse"] as! [[String: Any]] {
            let input = c["input"] as! String
            do {
                let r = try bible.parse(input)
                XCTAssertNil(c["error"], "\(input): expected error \(c["error"] ?? "")")
                XCTAssertEqual(r.query(), c["query"] as? String, input)
                XCTAssertEqual(r.logos(), c["logos"] as? String, input)
                XCTAssertEqual(r.isChapter, c["isChapter"] as? Bool, input)
                XCTAssertEqual(r.book.id, c["book"] as? String, input)
                XCTAssertEqual(r.v2, c["v2"] as? Int, input)
                XCTAssertTrue(sameJSON(sharedService.refPayload(r), c["payload"]!),
                              "\(input) payload\n  swift:  \(sharedService.refPayload(r))\n  python: \(c["payload"]!)")
                let nasb = translations.first { $0.id == "NASB" }!
                XCTAssertTrue(sameJSON(sharedService.links(nasb, r), c["links"]!),
                              "\(input) links: \(sharedService.links(nasb, r)) vs \(c["links"]!)")
            } catch let e as RefError {
                XCTAssertEqual(e.message, c["error"] as? String, input)
            }
        }
    }

    func testSplit() throws {
        let fx = try loadJSON("refs.json") as! [String: Any]
        for c in fx["split"] as! [[String: Any]] {
            let input = c["input"] as! String
            let (_, got) = sharedService.parsePayload(input)
            let parts = got["parts"] ?? []
            XCTAssertTrue(sameJSON(parts, c["parts"]!), "\(input)\n  swift:  \(parts)\n  python: \(c["parts"]!)")
        }
    }

    func testFindBook() throws {
        let fx = try loadJSON("refs.json") as! [String: Any]
        for (name, id) in fx["findBook"] as! [String: Any] {
            XCTAssertEqual(bible.findBook(name)?.id, id as? String, name)
        }
    }
}

final class ServiceTests: XCTestCase {
    func testBundledPassagesMatchPython() async throws {
        let fx = try loadJSON("passages.json") as! [String: Any]
        for c in fx["passages"] as! [[String: Any]] {
            let (status, body) = try await sharedService.passage(c["q"] as? String, c["t"] as? String)
            XCTAssertEqual(status, c["status"] as? Int)
            let expected = c["body"] as! [String: Any]
            for key in Set(expected.keys).union(body.keys) where !sameJSON(body[key] ?? NSNull(), expected[key] ?? NSNull()) {
                XCTFail("\(c["q"]!) \(c["t"]!) \(key)\n  swift:  \(body[key] ?? "nil")\n  python: \(expected[key] ?? "nil")")
            }
        }
    }

    func testConfigBooks() throws {
        let fx = try loadJSON("passages.json") as! [String: Any]
        XCTAssertTrue(sameJSON(sharedService.configPayload()["books"]!, fx["books"]!))
    }

    func testUnavailableWithoutKeys() async throws {
        let (status, body) = try await sharedService.passage("John 3:16", "esv")
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(body["unavailable"])
        XCTAssertEqual(body["settings"] as? Bool, true)
        XCTAssertNil(body["verses"])
    }

    func testAPIErrors() async throws {
        let bad = try JSONSerialization.jsonObject(with: await sharedService.handle(path: "/api/passage", query: ["q": "Hezekiah 1"]).body) as! [String: Any]
        XCTAssertEqual(bad["error"] as? String, "Couldn’t find a book called “Hezekiah”.")
        let r = await sharedService.handle(path: "/api/passage", query: ["q": "John 3:16", "t": "XYZ"])
        XCTAssertEqual(r.status, 400)
        let missing = await sharedService.handle(path: "/api/nope", query: [:])
        XCTAssertEqual(missing.status, 404)
        let empty = await sharedService.handle(path: "/api/parse", query: ["q": " ; "])
        XCTAssertEqual(empty.status, 400)
    }
}

final class HTMLEventParserTests: XCTestCase {
    final class Recorder: HTMLEventParser {
        var events: [String] = []
        override func handleStartTag(_ tag: String, _ attrs: Attrs) {
            events.append("<\(tag)" + attrs.map { " \($0.0)=\($0.1 ?? "∅")" }.joined() + ">")
        }
        override func handleEndTag(_ tag: String) { events.append("</\(tag)>") }
        override func handleData(_ data: String) { events.append(data) }
    }

    func events(_ html: String) -> [String] {
        let r = Recorder()
        r.feed(html)
        return r.events
    }

    func testTagsAndAttributes() {
        XCTAssertEqual(events(#"<P Class="a b" id=x checked data-q='1 "2"'>Hi</p>"#),
                       [#"<p class=a b id=x checked=∅ data-q=1 "2">"#, "Hi", "</p>"])
        XCTAssertEqual(events("a<br>b<br/>c<br />d"), ["a", "<br>", "b", "<br>", "</br>", "c", "<br>", "</br>", "d"])
        XCTAssertEqual(events("<verse_export ch=\"3\" vn=\"16\">x</verse_export>"),
                       ["<verse_export ch=3 vn=16>", "x", "</verse_export>"])
    }

    func testEntities() {
        XCTAssertEqual(unescapeHTML("5:1&nbsp;&amp;&lt;&#8220;x&#x201D;&copy2019&bogus;&#150;"),
                       "5:1\u{A0}&<“x”©2019&bogus;–")
        XCTAssertEqual(events("<a title=\"&quot;q&quot;\">&lt;b&gt;</a>"), ["<a title=\"q\">", "<b>", "</a>"])
    }

    func testCommentsScriptsAndStrayBrackets() {
        XCTAssertEqual(events("<!DOCTYPE html><!-- <p> -->a < b<script>if (a<b) x();</script>c"),
                       ["a ", "<", " b", "<script>", "if (a<b) x();", "</script>", "c"])
    }
}
