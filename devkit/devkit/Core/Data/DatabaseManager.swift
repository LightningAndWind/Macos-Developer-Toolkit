//
//  DatabaseManager.swift
//  devkit
//
//  SQLite3 数据库封装。M1 仅使用一张 kv 表存会话快照 JSON。
//

import Foundation
import SQLite3

/// SQLite3 数据库管理器（单例）。
///
/// - 通过 `open(at:)` 打开（或创建）指定路径的数据库文件
/// - 关闭时 `sqlite3_close`
/// - 简单线程模型：串行 queue + NSLock；M1 只在主 actor 使用
final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private(set) var fileURL: URL?

    private init() {}

    var isOpen: Bool { db != nil }

    /// 打开数据库；如果文件不存在会自动创建。
    func open(at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        if db != nil { _closeLocked() }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close_v2(handle) }
            throw DatabaseError.openFailed(msg)
        }
        self.db = handle
        self.fileURL = url
        try _migrateLocked()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        _closeLocked()
    }

    // MARK: - Migration (caller must hold lock)

    private func _migrateLocked() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS kv (
            key TEXT PRIMARY KEY,
            value BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS http_history (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            method TEXT NOT NULL,
            url TEXT NOT NULL,
            status_code INTEGER,
            duration_ms INTEGER,
            size_bytes INTEGER,
            saved_request_id TEXT,
            request_json BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_history_created ON http_history(created_at);
        CREATE INDEX IF NOT EXISTS idx_history_url ON http_history(url);
        CREATE INDEX IF NOT EXISTS idx_history_saved ON http_history(saved_request_id);
        CREATE TABLE IF NOT EXISTS http_folders(
            id TEXT PRIMARY KEY,
            parent_id TEXT,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_folder_parent ON http_folders(parent_id);
        CREATE TABLE IF NOT EXISTS http_requests(
            id TEXT PRIMARY KEY,
            folder_id TEXT,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            request_json BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_request_folder ON http_requests(folder_id);
        CREATE TABLE IF NOT EXISTS ssh_folders(
            id TEXT PRIMARY KEY,
            parent_id TEXT,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_sshfolder_parent ON ssh_folders(parent_id);
        CREATE TABLE IF NOT EXISTS ssh_profiles(
            id TEXT PRIMARY KEY,
            folder_id TEXT,
            name TEXT NOT NULL,
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            username TEXT NOT NULL,
            auth_kind TEXT NOT NULL,
            password TEXT,
            key_file TEXT,
            key_passphrase TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            profile_json BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_sshprofile_folder ON ssh_profiles(folder_id);
        CREATE TABLE IF NOT EXISTS ssh_known_hosts(
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            key_type TEXT NOT NULL,
            key_blob BLOB NOT NULL,
            added_at REAL NOT NULL,
            PRIMARY KEY(host, port, key_type)
        );
        """
        try _execLocked(sql)
    }

    private func _closeLocked() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        fileURL = nil
    }

    // MARK: - Basic ops (public: lock then delegate to unlocked core)

    @discardableResult
    func exec(_ sql: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try _execLocked(sql)
    }

    /// 单行查询：回调返回 false 可提前中止。
    func query(_ sql: String, bind: [SQLiteValue] = [], using block: (SQLiteRow) -> Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try _queryLocked(sql, bind: bind, using: block)
    }

    func run(_ sql: String, bind: [SQLiteValue] = []) throws {
        lock.lock(); defer { lock.unlock() }
        try _runLocked(sql, bind: bind)
    }

    // MARK: - Unlocked cores (caller must hold lock)

    @discardableResult
    private func _execLocked(_ sql: String) throws -> Int {
        guard let db else { throw DatabaseError.notOpen }
        var errMsg: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if code != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "sqlite error \(code)"
            sqlite3_free(errMsg)
            throw DatabaseError.execFailed(msg)
        }
        return Int(sqlite3_changes(db))
    }

    private func _queryLocked(_ sql: String, bind: [SQLiteValue], using block: (SQLiteRow) -> Bool) throws {
        guard let db else { throw DatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in bind.enumerated() { v.bind(to: stmt, index: Int32(i + 1)) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let row = SQLiteRow(stmt: stmt)
            if !block(row) { break }
        }
    }

    private func _runLocked(_ sql: String, bind: [SQLiteValue]) throws {
        guard let db else { throw DatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in bind.enumerated() { v.bind(to: stmt, index: Int32(i + 1)) }
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.stepFailed(msg)
        }
    }

    // MARK: - KV helpers

    func putKV(key: String, value: Data) throws {
        let sql = "INSERT INTO kv(key, value, updated_at) VALUES(?, ?, ?) " +
                  "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
        try run(sql, bind: [.text(key), .blob(value), .real(Date.now.timeIntervalSince1970)])
    }

    func getKV(key: String) throws -> Data? {
        var result: Data?
        try query("SELECT value FROM kv WHERE key = ?;", bind: [.text(key)]) { row in
            result = row.blob(0)
            return false
        }
        return result
    }

    enum DatabaseError: LocalizedError {
        case notOpen, openFailed(String), execFailed(String), prepareFailed(String), stepFailed(String)
        var errorDescription: String? {
            switch self {
            case .notOpen: return "数据库未打开"
            case .openFailed(let m): return "数据库打开失败：\(m)"
            case .execFailed(let m): return "SQL 执行失败：\(m)"
            case .prepareFailed(let m): return "SQL 预编译失败：\(m)"
            case .stepFailed(let m): return "SQL 步进失败：\(m)"
            }
        }
    }
}

// MARK: - SQLite value / row wrappers

enum SQLiteValue {
    case null
    case int(Int)
    case real(Double)
    case text(String)
    case blob(Data)

    func bind(to stmt: OpaquePointer?, index: Int32) {
        switch self {
        case .null:   _ = sqlite3_bind_null(stmt, index)
        case .int(let v):   _ = sqlite3_bind_int64(stmt, index, Int64(v))
        case .real(let v):  _ = sqlite3_bind_double(stmt, index, v)
        case .text(let v):  _ = sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
        case .blob(let v):  _ = v.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
        }
        }
    }
}

struct SQLiteRow {
    let stmt: OpaquePointer?
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    /// 可空整数列：SQL NULL 返回 nil，避免与真实的 0 混淆。
    func intOrNil(_ i: Int32) -> Int? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, i))
    }
    func real(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
    func blob(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        return Data(bytes: p, count: n)
    }
}

// SQLITE_TRANSIENT 是 C 宏，Swift 无法直接导入；用等价物手动定义。
@usableFromInline
internal let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
