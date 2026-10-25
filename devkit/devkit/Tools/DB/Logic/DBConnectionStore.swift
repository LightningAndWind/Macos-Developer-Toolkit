//
//  DBConnectionStore.swift
//  devkit
//
//  数据库连接（MySQL / Redis）持久化：复用 DatabaseManager 的 db_connections 表。
//  连接整条编入 conn_json blob，标量列为查询/排序冗余，解码以 blob 为准（编解码对称）。
//  db 未打开时静默降级（与 SSHProfileStore 一致）。无文件夹层级，扁平列表即可。
//

import Foundation

/// 连接存储（仅在主 actor 使用）。
@MainActor
enum DBConnectionStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// 保存连接：存在则整行更新（ON CONFLICT），否则插入。回填 updatedAt。
    static func save(_ connection: DBConnection) throws {
        guard DatabaseManager.shared.isOpen else { return }
        var stored = connection
        stored.updatedAt = .now
        let data = try encoder.encode(stored)
        try DatabaseManager.shared.run(
            """
            INSERT INTO db_connections(id, name, kind, host, port, username, password,
                                       database_name, created_at, updated_at, conn_json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                kind = excluded.kind,
                host = excluded.host,
                port = excluded.port,
                username = excluded.username,
                password = excluded.password,
                database_name = excluded.database_name,
                updated_at = excluded.updated_at,
                conn_json = excluded.conn_json;
            """,
            bind: [
                .text(stored.id.uuidString),
                .text(stored.name),
                .text(stored.kind.rawValue),
                .text(stored.host),
                .int(stored.port),
                stored.normalizedUsername.map { SQLiteValue.text($0) } ?? .null,
                stored.normalizedPassword.map { SQLiteValue.text($0) } ?? .null,
                stored.normalizedDatabase.map { SQLiteValue.text($0) } ?? .null,
                .real(stored.createdAt.timeIntervalSince1970),
                .real(stored.updatedAt.timeIntervalSince1970),
                .blob(data),
            ]
        )
    }

    static func load(id: UUID) -> DBConnection? {
        guard DatabaseManager.shared.isOpen else { return nil }
        var result: DBConnection?
        try? DatabaseManager.shared.query(
            "SELECT conn_json FROM db_connections WHERE id = ?;",
            bind: [.text(id.uuidString)]
        ) { row in
            if let blob = row.blob(0) {
                result = try? decoder.decode(DBConnection.self, from: blob)
            }
            return false
        }
        return result
    }

    static func all() -> [DBConnection] {
        guard DatabaseManager.shared.isOpen else { return [] }
        var results: [DBConnection] = []
        try? DatabaseManager.shared.query(
            "SELECT conn_json FROM db_connections ORDER BY name COLLATE NOCASE;"
        ) { row in
            if let blob = row.blob(0), let connection = try? decoder.decode(DBConnection.self, from: blob) {
                results.append(connection)
            }
            return true
        }
        return results
    }

    static func delete(_ id: UUID) {
        guard DatabaseManager.shared.isOpen else { return }
        try? DatabaseManager.shared.run("DELETE FROM db_connections WHERE id = ?;", bind: [.text(id.uuidString)])
    }
}
