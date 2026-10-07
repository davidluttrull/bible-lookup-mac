#!/usr/bin/env python3
"""Record test fixtures for the Swift app from this (reference) Python version.

    python3 python-reference/tools/make_fixtures.py

Writes Tests/BibleLookupCoreTests/Fixtures/:
  sources/*.html|json   raw responses from each online source (needs the keys in
                        python-reference/config.json)
  parsers.json          what the Python parser makes of each raw response
  refs.json             reference parsing, splitting, display names and links
  passages.json         whole /api/passage answers for the bundled KJV and ASV
The Swift tests feed the same raw responses to the Swift parsers and expect the same
output, so the two versions stay in step.
"""
import json
import os
import sys
import urllib.parse

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import providers as P  # noqa: E402
import server  # noqa: E402
from bibleref import RefError  # noqa: E402

OUT = os.path.join(os.path.dirname(HERE), "Tests", "BibleLookupCoreTests", "Fixtures")
SRC = os.path.join(OUT, "sources")

PASSAGES = [
    "John 3", "Psalm 23", "Psalm 119:1-16", "Matthew 5:1-12", "Mark 16:8-9", "Song of Songs 1:1-4",
    "Genesis 1:1-5", "Acts 9:1-6", "Romans 8:1-4", "Psalm 3", "Psalm 42:1-3", "Isaiah 53:1-6",
    "Luke 1:46-55", "3 John 1:13-15", "Revelation 12:17-18", "Mark 16:9-10", "Psalm 1",
]


def slug(q):
    return q.lower().replace(" ", "-").replace(":", "_")


def save(name, text):
    with open(os.path.join(SRC, name), "w", encoding="utf-8") as f:
        f.write(text)


def main():
    os.makedirs(SRC, exist_ok=True)
    cfg = server.with_env(server.load_config())
    app = server.App(cfg)
    cases = []

    def record(source, q, raw, ext, parse, **extra):
        name = f"{source}-{slug(q)}.{ext}"
        save(name, raw)
        cases.append({"source": source, "query": q, "file": name, "expected": parse(raw), **extra})
        print(f"  {name}")

    for q in PASSAGES:
        ref = app.bible.parse(q)
        # ESV: the same request the provider makes
        esv = app.translations["ESV"]["provider"]
        if esv.key:
            params = dict(ESV_PARAMS, q=ref.query())
            data = json.loads(P.http_get("https://api.esv.org/v3/passage/html/?" + urllib.parse.urlencode(params),
                                         {"Authorization": f"Token {esv.key}"}))

            def esv_parse(raw):
                p = P._ESVParser()
                p.feed(raw)
                p.close()
                return p.result()
            record("esv", q, "\n".join(data.get("passages") or []), "html", esv_parse)

        page = P.http_get("https://api.nlt.to/api/passages?" + urllib.parse.urlencode(
            {"ref": ref.query(), "version": "NLT", "key": app.translations["NLT"]["provider"].key}))

        def nlt_parse(raw):
            p = P._NLTParser()
            p.feed(raw)
            return p.verses
        record("nlt", q, page, "html", nlt_parse)

        body = P.http_get("https://labs.bible.org/api/?" + urllib.parse.urlencode(
            {"passage": ref.query(), "type": "json", "formatting": "plain"}))
        record("net", q, body, "json", net_parse)

        for tid in server.API_BIBLE_IDS:
            prov = app.translations[tid]["provider"]
            if not (prov.key and prov.bible_id):
                continue
            b = ref.book
            if ref.is_chapter:
                path = f"chapters/{b.id}.{ref.c1}"
            else:
                path = f"passages/{b.id}.{ref.c1}.{ref.v1}-{b.id}.{ref.c2}.{min(ref.v2, b.verse_counts[ref.c2 - 1])}"
            url = (f"https://rest.api.bible/v1/bibles/{prov.bible_id}/{path}?"
                   + urllib.parse.urlencode(API_BIBLE_PARAMS))
            content = json.loads(P.http_get(url, {"api-key": prov.key}))["data"].get("content", "")
            psalms = b.id == "PSA"

            def usx_parse(raw, psalms=psalms):
                p = P._USXParser(ms_is_heading=not psalms)  # "ms" blocks are headings outside the Psalms
                p.feed(raw)
                p.close()
                return p.result()
            record(tid.lower(), q, content, "html", usx_parse, psalms=psalms)

    with open(os.path.join(OUT, "parsers.json"), "w", encoding="utf-8") as f:
        json.dump(cases, f, ensure_ascii=False, indent=1)
    print(f"parsers.json: {len(cases)} cases")
    write_refs(app)
    write_passages(app)


def write_passages(app):
    out = []
    for q in ["John 3:16", "Psalm 23", "Psalm 119:1-9", "Acts 9:4-6", "Mark 16:8-10", "Gen 1-2", "Jude 5",
              "Rev 22", "3 John 1:15", "Matthew 5:1-12", "Luke 1:46-55", "Song 1:1-4"]:
        for t in ["KJV", "ASV"]:
            status, obj = app.passage(q, t)
            out.append({"q": q, "t": t, "status": status, "body": obj})
    with open(os.path.join(OUT, "passages.json"), "w", encoding="utf-8") as f:
        json.dump({"passages": out, "books": app.config_payload()["books"]}, f, ensure_ascii=False, indent=1)
    print(f"passages.json: {len(out)} answers")


def net_parse(raw):
    """NET.fetch without the network call or the range filter."""
    rows = json.loads(raw)
    verses = []
    for r in rows:
        text = P.html.escape(r.get("text", ""), quote=False)
        verses.append({"c": int(r["chapter"]), "v": int(r["verse"]),
                       "h": P.clean_space(text), "p": bool(r.get("title")) or not verses})
    return verses


ESV_PARAMS = {
    "include-passage-references": "false", "include-verse-numbers": "true",
    "include-first-verse-numbers": "true", "include-chapter-numbers": "true",
    "include-footnotes": "false", "include-footnote-body": "false", "include-headings": "true",
    "include-subheadings": "true", "include-short-copyright": "false", "include-copyright": "false",
    "include-audio-link": "false", "include-book-titles": "false", "include-crossrefs": "false",
    "include-surrounding-chapters": "false", "include-selahs": "true", "wrapping-div": "false",
    "include-css-link": "false", "inline-styles": "false",
}
API_BIBLE_PARAMS = {
    "content-type": "html", "include-notes": "false", "include-titles": "true",
    "include-chapter-numbers": "false", "include-verse-numbers": "true", "include-verse-spans": "false",
}

REF_INPUTS = [
    "John 3:16", "jn 3:16", "Jn3.16", "john 3 16", "  JOHN   3 : 16 ", "John 3:16-18", "John 3:16–18",
    "John 3:36-4:2", "Gen 1-2", "Psalm 23", "Romans", "1 John 1:9", "1John 1:9", "1jn 1:9", "I John 1:9",
    "First John 1:9", "1st John 1:9", "II Tim 3:16", "3 jn 4", "Song of Solomon 2:1", "Phil 4:13",
    "Phlm 1:4", "Is 53:5", "Isa 53:5", "Rev 22:21", "revel 1:1", "Ecc 3:1", "Jude 5", "Jude 3-5", "Jude 1:5",
    "Jude 1", "Obadiah", "3 John 1:15", "John 3:16-99", "", "Hezekiah 3:1", "John 30", "John 3:50",
    "John 3:18-16", "Psalm 151", "123", "Ps 119:176", "Ps 119:177", "Ps 119:178", "Gen 50:1-99", "Gen 49:1-50:3",
    "Gen 2-1", "Gen 1:5-", "John 3:", "John 3.", "Mt 5:3-7:29", "Philemon 3", "Phm 1-3", "2 John 1-2", "jud 1:1-3",
    "Song 1:1", "Canticles 2", "Qoh 1", "iii john 2", "Third John 2", "3rd jn 2", "second kings 2:11",
    "Ps 23:1–6", "Ps 23:1—6", "Ps 23 : 1 - 6", "John 3 16 - 18", "Revelations 1", "apocalypse 1:1", "j 1",
    "jo 1:1", "jud 5", "ju 5", "ph 1", "phi 1", "ma 1", "1 c 13", "1 cor 13:4-7", "1co13", "2 Ch 7:14",
    "Dt 6:4", "Eze 37", "Ezk 37:1", "Mk 1", "Lk 2:1-20", "Ac 2", "Ro 8:28", "Heb 11", "Jas 1:5", "Rev 22",
    "Rev 22:22", "Rev 23", "3 John 1:16", "Rev 12:18", "Mal 4:6", "Mal 4:7", "Mal 4:8", "Psalms 1-150",
    "Psalms 150-151", "John 3:16-4", "John 3:16-4:", "Gen 1:1-1:1", "Jn 3:0", "Jn 0", "Gen 1:1-2:0",
    "John three", "Joh", "Ps.23", "Ps. 23", "Gn 1:1", "Jer 29:11", "Lam 3:22-23", "Hab 2:4", "Zp 3:17",
    "Hos 1", "Jl 2:28", "Am 5:24", "Ob 1", "Ob 1:21", "Ob 21", "Ob 22", "Jon 2", "Jnh 1:17", "Mc 6:8", "Na 1:7",
    "Hg 2", "Zc 9:9", "Ml 3:10", "Mr 1", "Lu 1", "Jhn 1", "Ga 5:22", "Ephes 2:8", "Pp 4", "Tt 2", "Ti 2",
    "Philem 1:6", "Phile 6", "1 Pt 5:7", "2 P 1", "1 J 4:8", "3 J 1", "Jd 24", "Rv 21", "1s 17", "2 s 7",
    "1 K 18", "2k 2", "1chron 16", "Esth 4:14", "Jb 1", "Prv 3:5-6", "Eccles 3", "Sos 2:4", "Ss 1",
    "Isaiah 9:6-7; John 1:14", "James 1:5; John 3:16-18", "John 3:16; 4:2", "John 3:16; 17",
    "John 3:16; 1 John 1:9; 2:1", "Hezekiah 1; Ps 23;;", " ; ", "Ps 23; 24; 25:1-3", "Jude 5; 7",
    "Jn 3:16; 3:17-4:1; x", "1 Cor 13; 2 Cor 5:17", "a;b;c",
    # commas: after one, a bare number continues the same chapter ("Heb 10:11-14, 18")
    "Hebrews 9:23-28; 10:11-14, 18; Hebrews 7:27", "John 3:16, 18-20", "John 3:16, 4:2",
    "John 3:36-4:2, 5", "Ps 23, 24", "Jude 3, 5", "John 3:16, Rom 5:8, 6:23", "John 3:16,, 17 ,",
    "Isa. 53:6,", " ;Isa 53:6 ; ", "John 3:16, 99", ", ".join(["John 3:16"] * 20),
    ";".join(f"Gen {i}" for i in range(1, 16)),
]


def write_refs(app):
    refs = []
    for s in REF_INPUTS:
        try:
            r = app.bible.parse(s)
        except RefError as e:
            refs.append({"input": s, "error": str(e)})
            continue
        refs.append({"input": s, "query": r.query(), "logos": r.logos(), "isChapter": r.is_chapter,
                     "payload": app.ref_payload(r),
                     "links": app.links(app.translations["NASB"], r),
                     "c1": r.c1, "v1": r.v1, "c2": r.c2, "v2": r.v2, "book": r.book.id})
    splits = []
    for s in REF_INPUTS:
        if ";" not in s and "," not in s:
            continue
        parts = []
        for text, r in app.bible.split(s):
            if isinstance(r, RefError):
                parts.append({"input": text, "error": str(r)})
            else:
                name = "Psalm" if r.book.id == "PSA" and r.c1 == r.c2 else None
                parts.append({"input": text, "query": r.query(name)})
        splits.append({"input": s, "parts": parts})
    # every alias of every book should resolve the same way
    finds = {}
    from bibleref import BOOKS
    for bid, name, logos, aliases in BOOKS:
        for a in [name, bid, *aliases.split(), name[:3], name[:4], name.lower(), name.upper()]:
            b = app.bible.find_book(a)
            finds[a] = b.id if b else None
    with open(os.path.join(OUT, "refs.json"), "w", encoding="utf-8") as f:
        json.dump({"parse": refs, "split": splits, "findBook": finds}, f, ensure_ascii=False, indent=1)
    print(f"refs.json: {len(refs)} parses, {len(splits)} splits, {len(finds)} book names")


if __name__ == "__main__":
    main()
