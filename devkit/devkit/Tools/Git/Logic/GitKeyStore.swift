//
//  GitKeyStore.swift
//  devkit
//
//  Git 密钥对的持久化（git_keys 表）。整条编入 key_json blob，标量列为查询冗余，解码以 blob 为准
//  （编解码对称，同 SSHProfileStore）。删除密钥时连带清除 git_keys/ 内文件，并把引用它的仓库解绑。
//

import Foundation

@MainActor
enum GitKeyStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// 保存密钥：存在则整行更新，否则插入。回填 updatedAt。
    static func save(_ key: GitKey) throws {
        guard DatabaseManager.shared.isOpen else { return }
        var stored = key
        stored.updatedAt = .now
        let data = try encoder.encode(stored)
        try DatabaseManager.shared.run(
            """
            INSERT INTO git_keys(id, name, algorithm, comment, public_key, private_file,
                                 has_passphrase, imported, created_at, updated_at, key_json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                algorithm = excluded.algorithm,
                comment = excluded.comment,
                public_key = excluded.public_key,
                private_file = excluded.private_file,
                has_passphrase = excluded.has_passphrase,
                imported = excluded.imported,
                updated_at = excluded.updated_at,
                key_json = excluded.key_json;
            """,
            bind: [
                .text(stored.id.uuidString),
                .text(stored.name),
                .text(stored.algorithm.rawValue),
                .text(stored.comment),
                .text(stored.publicKey),
                stored.privateFileName.map { SQLiteValue.text($0) } ?? .null,
                .int(stored.hasPassphrase ? 1 : 0),
                .int(stored.imported ? 1 : 0),
                .real(stored.createdAt.timeIntervalSince1970),
                .real(stored.updatedAt.timeIntervalSince1970),
                .blob(data),
            ]
        )
    }

    static func load(id: UUID) -> GitKey? {
        guard DatabaseManager.shared.isOpen else { return nil }
        var result: GitKey?
        try? DatabaseManager.shared.query(
            "SELECT key_json FROM git_keys WHERE id = ?;",
            bind: [.text(id.uuidString)]
        ) { row in
            if let blob = row.blob(0) {
                result = try? decoder.decode(GitKey.self, from: blob)
            }
            return false
        }
        return result
    }

    static func all() -> [GitKey] {
        guard DatabaseManager.shared.isOpen else { return [] }
        var results: [GitKey] = []
        try? DatabaseManager.shared.query(
            "SELECT key_json FROM git_keys ORDER BY name COLLATE NOCASE;"
        ) { row in
            if let blob = row.blob(0), let key = try? decoder.decode(GitKey.self, from: blob) {
                results.append(key)
            }
            return true
        }
        return results
    }

    /// 删除密钥：移除记录 + 文件；把引用它的仓库解绑（key_id 置空）。
    static func delete(id: UUID) {
        guard DatabaseManager.shared.isOpen else { return }
        if let key = load(id: id), let fileName = key.privateFileName {
            GitKeyStorage.delete(fileName: fileName)
        }
        try? DatabaseManager.shared.run(
            "UPDATE git_repos SET key_id = NULL WHERE key_id = ?;",
            bind: [.text(id.uuidString)]
        )
        try? DatabaseManager.shared.run("DELETE FROM git_keys WHERE id = ?;", bind: [.text(id.uuidString)])
    }
}
