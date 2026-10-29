// SPDX-License-Identifier: Apache-2.0

import CSQLite
import Darwin
import Foundation

// SQLite must copy Swift-owned bytes before the temporary buffer leaves scope.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteStoreError: Error, LocalizedError {
    case open(String, Int32)
    case statement(String, Int32)
    case step(String, Int32)
    case decode(String)
    case migrationLocked
    case unsupportedSchema(Int)

    public var isCorruption: Bool {
        let code: Int32
        switch self {
        case .open(_, let value), .statement(_, let value), .step(_, let value): code = value & 0xFF
        default: return false
        }
        return code == SQLITE_CORRUPT || code == SQLITE_NOTADB
    }

    public var errorDescription: String? {
        switch self {
        case .open(let value, _): return "Could not open Rationbook database: \(value)"
        case .statement(let value, _): return "Could not prepare Rationbook database statement: \(value)"
        case .step(let value, _): return "Rationbook database operation failed: \(value)"
        case .decode(let value): return "Could not decode cached Rationbook data: \(value)"
        case .migrationLocked: return "Another Rationbook process is migrating the database."
        case .unsupportedSchema(let version): return "Rationbook database schema \(version) is newer than this build supports."
        }
    }
}

// The recursive lock serializes every SQLite connection and statement operation.
public final class SQLiteStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let paths: RationbookPaths

    public init(paths: RationbookPaths = RationbookPaths()) throws {
        self.paths = paths
        try paths.prepare()
        guard let migrationLock = ProviderRefreshLock(provider: "database-migration", paths: paths) else {
            throw SQLiteStoreError.migrationLocked
        }
        if !FileManager.default.fileExists(atPath: paths.database.path) {
            let descriptor = open(paths.database.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw RationbookPathError.unsafePath(paths.database.path) }
            close(descriptor)
        }
        try paths.validateFileForRead(paths.database)
        var connection: OpaquePointer?
        // Darwin's bundled SQLite reports SQLITE_CANTOPEN_SYMLINK for some
        // canonical temporary roots when SQLITE_OPEN_NOFOLLOW is supplied.
        // The leaf is therefore created with O_NOFOLLOW above and validated
        // both before and immediately after SQLite opens it.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(paths.database.path, &connection, flags, nil) == SQLITE_OK, let connection else {
            let detail = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            let code = connection.map(sqlite3_extended_errcode) ?? SQLITE_CANTOPEN
            sqlite3_close(connection)
            throw SQLiteStoreError.open(detail, code)
        }
        db = connection
        do {
            try paths.validateFileForRead(paths.database)
            guard chmod(paths.database.path, 0o600) == 0 else {
                throw RationbookPathError.unsafePath(paths.database.path)
            }
            try paths.validateFileForRead(paths.database)
        } catch {
            sqlite3_close(connection)
            db = nil
            throw error
        }
        try execute("PRAGMA busy_timeout=1500;")
        // Keep the cross-process lock alive through the complete schema transaction.
        try withExtendedLifetime(migrationLock) { try migrate() }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
    }

    deinit {
        sqlite3_close(db)
    }

    public func save(_ provider: ProviderStatus, recordHistory: Bool = true) throws {
        try QuotaValidation.windows(provider.windows)
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let payload = try RationbookJSON.encoder().encode(provider)
            let observed = provider.windows.map(\.observedAt).max() ?? Date()
            try withStatement("""
                INSERT INTO latest_provider(provider, observed_at, payload)
                VALUES(?, ?, ?)
                ON CONFLICT(provider) DO UPDATE SET observed_at=excluded.observed_at, payload=excluded.payload;
                """) { statement in
                bind(provider.provider, at: 1, statement: statement)
                sqlite3_bind_double(statement, 2, observed.timeIntervalSince1970)
                _ = payload.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
                try stepDone(statement)
            }
            if recordHistory {
                for window in provider.windows { try saveWindow(provider: provider.provider, window: window) }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func latestProvider(_ provider: String) throws -> ProviderStatus? {
        lock.lock()
        defer { lock.unlock() }
        return try withStatement("SELECT payload FROM latest_provider WHERE provider=?;") { statement in
            bind(provider, at: 1, statement: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            do { return try RationbookJSON.decoder().decode(ProviderStatus.self, from: data) }
            catch { throw SQLiteStoreError.decode(error.localizedDescription) }
        }
    }

    public func history(provider: String? = nil, windowID: String? = nil, limit: Int = 500) throws -> [WindowSample] {
        lock.lock()
        defer { lock.unlock() }
        var clauses: [String] = []
        if provider != nil { clauses.append("provider=?") }
        if windowID != nil { clauses.append("window_id=?") }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let sql = """
            SELECT provider, window_id, used_percent, remaining_percent, expected_reset,
                   first_observed_at, last_observed_at, sample_count, freshness
            FROM window_observations\(whereClause)
            ORDER BY last_observed_at DESC LIMIT ?;
            """
        return try withStatement(sql) { statement in
            var index: Int32 = 1
            if let provider { bind(provider, at: index, statement: statement); index += 1 }
            if let windowID { bind(windowID, at: index, statement: statement); index += 1 }
            sqlite3_bind_int(statement, index, Int32(max(1, min(limit, 10_000))))
            var rows: [WindowSample] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(WindowSample(
                    provider: columnText(statement, 0),
                    windowID: columnText(statement, 1),
                    usedPercent: sqlite3_column_double(statement, 2),
                    remainingPercent: sqlite3_column_double(statement, 3),
                    expectedResetsAt: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    firstObservedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    lastObservedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    sampleCount: Int(sqlite3_column_int(statement, 7)),
                    freshness: Freshness(rawValue: columnText(statement, 8)) ?? .unknown
                ))
            }
            return rows
        }
    }

    public func prune(before cutoff: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        try withStatement("DELETE FROM window_observations WHERE last_observed_at < ?;") { statement in
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    public func value<T: Decodable>(forKey key: String, as type: T.Type = T.self) throws -> T? {
        lock.lock()
        defer { lock.unlock() }
        return try withStatement("SELECT value FROM settings WHERE key=?;") { statement in
            bind(key, at: 1, statement: statement)
            guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            return try RationbookJSON.decoder().decode(T.self, from: data)
        }
    }

    public func set<T: Encodable>(_ value: T, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try RationbookJSON.encoder().encode(value)
        try withStatement("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;") { statement in
            bind(key, at: 1, statement: statement)
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
            }
            try stepDone(statement)
        }
    }

    @discardableResult
    public func pruneIfNeeded(retentionDays: Int?, now: Date = Date(), force: Bool = false) throws -> Bool {
        let last: Date? = try value(forKey: "last_pruned_at")
        if !force, let last, now.timeIntervalSince(last) < 86_400 { return false }
        if let retentionDays {
            try prune(before: now.addingTimeInterval(-Double(max(1, retentionDays)) * 86_400))
        }
        try set(now, forKey: "last_pruned_at")
        return true
    }

    private func migrate() throws {
        try execute("BEGIN EXCLUSIVE;")
        do {
            try execute("""
            CREATE TABLE IF NOT EXISTS schema_meta (
                version INTEGER NOT NULL
            );
            """)
            let version = try schemaVersion()
            if let version, version > 1 { throw SQLiteStoreError.unsupportedSchema(version) }
            try execute("""
            CREATE TABLE IF NOT EXISTS latest_provider (
                provider TEXT PRIMARY KEY,
                observed_at REAL NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS window_observations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                provider TEXT NOT NULL,
                window_id TEXT NOT NULL,
                used_percent REAL NOT NULL,
                remaining_percent REAL NOT NULL,
                expected_reset REAL,
                first_observed_at REAL NOT NULL,
                last_observed_at REAL NOT NULL,
                sample_count INTEGER NOT NULL DEFAULT 1,
                freshness TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_window_history
            ON window_observations(provider, window_id, last_observed_at DESC);
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value BLOB NOT NULL
            );
            INSERT INTO schema_meta(version)
            SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_meta);
            """)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func schemaVersion() throws -> Int? {
        try withStatement("SELECT MAX(version) FROM schema_meta;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func saveWindow(provider: String, window: QuotaWindow) throws {
        let expected = window.expectedResetsAt?.timeIntervalSince1970
        let canonicalUsed = (window.usedPercent * 1_000).rounded() / 1_000
        let latest: (Int64, Double, Double?)? = try withStatement("""
            SELECT id, used_percent, expected_reset
            FROM window_observations WHERE provider=? AND window_id=?
            ORDER BY id DESC LIMIT 1;
            """) { statement in
            bind(provider, at: 1, statement: statement)
            bind(window.id, at: 2, statement: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (
                sqlite3_column_int64(statement, 0),
                sqlite3_column_double(statement, 1),
                sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2)
            )
        }

        if let latest,
           abs(latest.1 - canonicalUsed) < 0.000_5,
           latest.2 == expected {
            try withStatement("""
                UPDATE window_observations
                SET last_observed_at=MAX(last_observed_at, ?),
                    sample_count=sample_count + CASE WHEN ? > last_observed_at THEN 1 ELSE 0 END
                WHERE id=?;
                """) { statement in
                sqlite3_bind_double(statement, 1, window.observedAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 2, window.observedAt.timeIntervalSince1970)
                sqlite3_bind_int64(statement, 3, latest.0)
                try stepDone(statement)
            }
            return
        }

        let payload = try RationbookJSON.encoder().encode(window)
        try withStatement("""
            INSERT INTO window_observations(
                provider, window_id, used_percent, remaining_percent, expected_reset,
                first_observed_at, last_observed_at, sample_count, freshness, payload
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?);
            """) { statement in
            bind(provider, at: 1, statement: statement)
            bind(window.id, at: 2, statement: statement)
            sqlite3_bind_double(statement, 3, canonicalUsed)
            sqlite3_bind_double(statement, 4, window.remainingPercent)
            if let expected { sqlite3_bind_double(statement, 5, expected) } else { sqlite3_bind_null(statement, 5) }
            sqlite3_bind_double(statement, 6, window.observedAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 7, window.observedAt.timeIntervalSince1970)
            bind(window.freshness.rawValue, at: 8, statement: statement)
            _ = payload.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 9, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
            }
            try stepDone(statement)
        }
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? message
            sqlite3_free(errorMessage)
            throw SQLiteStoreError.step(detail, sqlite3_extended_errcode(db))
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteStoreError.statement(message, sqlite3_extended_errcode(db))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteStoreError.step(message, sqlite3_extended_errcode(db)) }
    }

    private func bind(_ value: String, at index: Int32, statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private var message: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error" }
}
