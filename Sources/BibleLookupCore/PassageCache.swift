import Foundation
import SQLite3

/// Passages from the online translations, kept on disk (SQLite) so they survive
/// restarts. A port of python-reference/passage_cache.py.
///
/// The ESV API's terms limit how much of its text may be stored: "You may not locally
/// store more than 500 verses or one-half of any book of the Bible (whichever is
/// less)." So for the ESV only (`limited`):
///
///   * at most `maxVerses` verses in total, and
///   * at most half of any one book (Jude has 25 verses, so at most 12 of Jude).
///
/// ESV passages are dropped least-recently-used first to stay inside both limits, and
/// one too long to store is always fetched live. Overlapping passages (John 3 and
/// John 3:16) are counted separately, which only ever errs on the side of storing less.
/// The other translations publish no caching rule, so their cache has no size limit.
///
/// Passages are kept forever by default: translations change rarely and only in minor
/// ways. `maxAgeDays` throws away passages older than that, so they're fetched fresh.
public final class PassageCache: @unchecked Sendable {
    public static let maxVerses = 500
    static let limited: Set<String> = ["ESV"]

    private static let schema = """
        CREATE TABLE IF NOT EXISTS passages (
            tid    TEXT NOT NULL,     -- translation id
            ref    TEXT NOT NULL,     -- normalized reference, e.g. "John 3:16-18"
            book   TEXT NOT NULL,     -- book id, for the half-a-book limit
            n      INTEGER NOT NULL,  -- verse count
            result TEXT NOT NULL,     -- the JSON sent to the page
            fums   TEXT NOT NULL,     -- API.Bible view-report tokens (JSON list)
            time   REAL NOT NULL,     -- when it was fetched
            used   REAL NOT NULL,     -- when it was last shown
            PRIMARY KEY (tid, ref)
        );
        CREATE INDEX IF NOT EXISTS passages_used ON passages (tid, used);
        """

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let maxAge: TimeInterval

    /// path nil (or a file that can't be opened) keeps the cache in memory.
    public init(path: URL?, maxAgeDays: Int = 0) {
        maxAge = TimeInterval(maxAgeDays) * 86400
        if !(path.map(open) ?? false) {
            sqlite3_open(":memory:", &db)
        }
        exec(Self.schema)
        expire()
    }

    deinit { sqlite3_close(db) }

    private func open(_ url: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])  // private
        }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              sqlite3_exec(db, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) == SQLITE_OK else {
            NSLog("note: can’t open cache \(url.path); keeping it in memory")
            sqlite3_close(db)
            db = nil
            return false
        }
        return true
    }

    private func expire() {
        guard maxAge > 0 else { return }
        locked { run("DELETE FROM passages WHERE time < ?", [Date().timeIntervalSince1970 - maxAge]) }
    }

    // MARK: - get / put

    /// (result, fums tokens) for a fresh cached passage, else nil.
    public func get(_ tid: String, _ ref: Ref) -> (result: [String: Any], fums: [String])? {
        let key = ref.query()
        return locked {
            guard let row = first("SELECT result, fums, time FROM passages WHERE tid = ? AND ref = ?", [tid, key]),
                  case .text(let resultJSON) = row[0], case .text(let fumsJSON) = row[1],
                  case .real(let time) = row[2] else { return nil }
            if maxAge > 0 && Date().timeIntervalSince1970 - time > maxAge {
                run("DELETE FROM passages WHERE tid = ? AND ref = ?", [tid, key])
                return nil
            }
            run("UPDATE passages SET used = ? WHERE tid = ? AND ref = ?", [Date().timeIntervalSince1970, tid, key])
            guard let result = (try? JSONSerialization.jsonObject(with: Data(resultJSON.utf8))) as? [String: Any] else {
                return nil
            }
            let fums = (try? JSONSerialization.jsonObject(with: Data(fumsJSON.utf8))) as? [String] ?? []
            return (result, fums)
        }
    }

    public func put(_ tid: String, _ ref: Ref, _ result: [String: Any], _ fums: [String]) {
        let n = (result["verses"] as? [Any])?.count ?? 0
        let book = ref.book.id
        guard let resultData = try? JSONSerialization.data(withJSONObject: result),
              let fumsData = try? JSONSerialization.data(withJSONObject: fums) else { return }
        locked {
            transaction {
                run("DELETE FROM passages WHERE tid = ? AND ref = ?", [tid, ref.query()])
                if Self.limited.contains(tid)
                    && !makeRoom(tid, book, n, bookLimit: ref.book.verseCounts.reduce(0, +) / 2) {
                    return  // too long to store under the limits; always fetched live
                }
                let now = Date().timeIntervalSince1970
                run("INSERT INTO passages VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    [tid, ref.query(), book, n, String(decoding: resultData, as: UTF8.self),
                     String(decoding: fumsData, as: UTF8.self), now, now])
            }
        }
    }

    /// Forget one translation's passages (e.g. its API.Bible edition changed).
    public func clear(_ tid: String) {
        locked { run("DELETE FROM passages WHERE tid = ?", [tid]) }
    }

    /// Drop tid's least recently used passages until n more verses fit. False if they never can.
    private func makeRoom(_ tid: String, _ book: String, _ n: Int, bookLimit: Int) -> Bool {
        if n > min(Self.maxVerses, bookLimit) { return false }
        func used(inBook: Bool) -> Int {
            let sql = "SELECT COALESCE(SUM(n), 0) FROM passages WHERE tid = ?" + (inBook ? " AND book = ?" : "")
            if case .int(let v) = first(sql, inBook ? [tid, book] : [tid])?[0] { return v }
            return 0
        }
        while used(inBook: false) + n > Self.maxVerses || used(inBook: true) + n > bookLimit {
            // over the total: any passage helps; only over the book: only that book's
            let inBook = used(inBook: false) + n <= Self.maxVerses
            let sql = "SELECT ref FROM passages WHERE tid = ?" + (inBook ? " AND book = ?" : "")
                + " ORDER BY used, rowid LIMIT 1"
            guard case .text(let oldest) = first(sql, inBook ? [tid, book] : [tid])?[0] else { break }
            run("DELETE FROM passages WHERE tid = ? AND ref = ?", [tid, oldest])
        }
        return true
    }

    public func stats() -> [String: (passages: Int, verses: Int)] {
        locked {
            var out: [String: (passages: Int, verses: Int)] = [:]
            for row in all("SELECT tid, COUNT(*), SUM(n) FROM passages GROUP BY tid", []) {
                if case .text(let tid) = row[0], case .int(let p) = row[1], case .int(let v) = row[2] {
                    out[tid] = (p, v)
                }
            }
            return out
        }
    }

    /// Tests only: pretend every passage was fetched at `time`.
    func setFetchTime(_ time: TimeInterval) {
        locked { run("UPDATE passages SET time = ?", [time]) }
    }

    // MARK: - SQLite plumbing

    private enum Value {
        case int(Int), real(Double), text(String), null
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func transaction(_ body: () -> Void) {
        exec("BEGIN")
        body()
        exec("COMMIT")
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [Any]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    @discardableResult
    private func run(_ sql: String, _ args: [Any]) -> Bool {
        guard let stmt = prepare(sql, args) else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func all(_ sql: String, _ args: [Any]) -> [[Value]] {
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [[Value]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(stmt)).map { i in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: return .int(Int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(stmt, i)))
                default: return .null
                }
            })
        }
        return rows
    }

    private func first(_ sql: String, _ args: [Any]) -> [Value]? {
        all(sql, args).first
    }
}
