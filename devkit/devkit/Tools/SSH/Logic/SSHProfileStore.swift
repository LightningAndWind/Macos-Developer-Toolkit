//
//  SSHProfileStore.swift
//  devkit
//
//  M4：SSH 集合（多级文件夹 + 连接配置）持久化。复用 DatabaseManager 的
//  ssh_folders / ssh_profiles 两张表；db 未打开时静默降级（与 HTTPCollectionStore 一致）。
//  profile 整条编入 profile_json blob，标量列为查询/排序冗余，解码以 blob 为准（编解码对称）。
//

import Foundation

/// 集合存储（仅在主 actor 使用）。
@MainActor
enum SSHProfileStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Folders

    /// 新建文件夹；`parentID == nil` 落在根。返回创建后的模型（db 未开返回 nil）。
    @discardableResult
    static func createFolder(name: String, parentID: UUID?) -> SSHFolder? {
        guard DatabaseManager.shared.isOpen else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = SSHFolder(parentID: parentID, name: trimmed.isEmpty ? "未命名文件夹" : trimmed)
        let now = folder.createdAt.timeIntervalSince1970
        try? DatabaseManager.shared.run(
            """
            INSERT INTO ssh_folders(id, parent_id, name, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?);
            """,
            bind: [
                .text(folder.id.uuidString),
                folder.parentID.map { SQLiteValue.text($0.uuidString) } ?? .null,
                .text(folder.name),
                .real(now),
                .real(now),
            ]
        )
        return folder
    }

    static func renameFolder(id: UUID, name: String) {
        guard DatabaseManager.shared.isOpen else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? DatabaseManager.shared.run(
            "UPDATE ssh_folders SET name = ?, updated_at = ? WHERE id = ?;",
            bind: [.text(trimmed), .real(Date.now.timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    /// 删除文件夹：级联删除所有子孙文件夹及其中的连接（含其私钥文件）。
    static func deleteFolder(id: UUID) {
        guard DatabaseManager.shared.isOpen else { return }
        let folders = allFolders()
        var toDelete: Set<UUID> = [id]
        var frontier: [UUID] = [id]
        while let current = frontier.popLast() {
            for f in folders where f.parentID == current && !toDelete.contains(f.id) {
                toDelete.insert(f.id)
                frontier.append(f.id)
            }
        }
        for fid in toDelete {
            let text = fid.uuidString
            // 先删该文件夹内 profile（连带私钥文件）。
            for profile in allRequests() where profile.folderID == fid {
                delete(profile.id)
            }
            try? DatabaseManager.shared.run("DELETE FROM ssh_folders WHERE id = ?;", bind: [.text(text)])
        }
    }

    static func allFolders() -> [SSHFolder] {
        guard DatabaseManager.shared.isOpen else { return [] }
        var results: [SSHFolder] = []
        try? DatabaseManager.shared.query(
            "SELECT id, parent_id, name, created_at, updated_at FROM ssh_folders ORDER BY name COLLATE NOCASE;"
        ) { row in
            guard let id = UUID(uuidString: row.text(0) ?? ""),
                  let name = row.text(2)
            else { return true }
            let parentID = row.text(1).flatMap { UUID(uuidString: $0) }
            results.append(SSHFolder(id: id,
                                     parentID: parentID,
                                     name: name,
                                     createdAt: Date(timeIntervalSince1970: row.real(3)),
                                     updatedAt: Date(timeIntervalSince1970: row.real(4))))
            return true
        }
        return results
    }

    // MARK: - Profiles

    /// 保存连接：存在则整行更新（ON CONFLICT），否则插入。回填 updatedAt。
    static func save(_ profile: SSHProfile) throws {
        guard DatabaseManager.shared.isOpen else { return }
        var stored = profile
        stored.updatedAt = .now
        let data = try encoder.encode(stored)
        try DatabaseManager.shared.run(
            """
            INSERT INTO ssh_profiles(id, folder_id, name, host, port, username, auth_kind,
                                     password, key_file, key_passphrase, created_at, updated_at, profile_json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                folder_id = excluded.folder_id,
                name = excluded.name,
                host = excluded.host,
                port = excluded.port,
                username = excluded.username,
                auth_kind = excluded.auth_kind,
                password = excluded.password,
                key_file = excluded.key_file,
                key_passphrase = excluded.key_passphrase,
                updated_at = excluded.updated_at,
                profile_json = excluded.profile_json;
            """,
            bind: [
                .text(stored.id.uuidString),
                stored.folderID.map { SQLiteValue.text($0.uuidString) } ?? .null,
                .text(stored.name),
                .text(stored.host),
                .int(stored.port),
                .text(stored.username),
                .text(stored.authKind.rawValue),
                stored.password.map { SQLiteValue.text($0) } ?? .null,
                stored.privateKeyFileName.map { SQLiteValue.text($0) } ?? .null,
                stored.keyPassphrase.map { SQLiteValue.text($0) } ?? .null,
                .real(stored.createdAt.timeIntervalSince1970),
                .real(stored.updatedAt.timeIntervalSince1970),
                .blob(data),
            ]
        )
    }

    static func load(id: UUID) -> SSHProfile? {
        guard DatabaseManager.shared.isOpen else { return nil }
        var result: SSHProfile?
        try? DatabaseManager.shared.query(
            "SELECT profile_json FROM ssh_profiles WHERE id = ?;",
            bind: [.text(id.uuidString)]
        ) { row in
            if let blob = row.blob(0) {
                result = try? decoder.decode(SSHProfile.self, from: blob)
            }
            return false
        }
        return result
    }

    static func allRequests() -> [SSHProfile] {
        guard DatabaseManager.shared.isOpen else { return [] }
        var results: [SSHProfile] = []
        try? DatabaseManager.shared.query(
            "SELECT profile_json FROM ssh_profiles ORDER BY name COLLATE NOCASE;"
        ) { row in
            if let blob = row.blob(0), let profile = try? decoder.decode(SSHProfile.self, from: blob) {
                results.append(profile)
            }
            return true
        }
        return results
    }

    /// 仅改名（供标签标题双向同步）。
    static func renameProfile(id: UUID, name: String) {
        guard DatabaseManager.shared.isOpen else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? DatabaseManager.shared.run(
            "UPDATE ssh_profiles SET name = ?, updated_at = ? WHERE id = ?;",
            bind: [.text(trimmed), .real(Date.now.timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    static func moveProfile(id: UUID, to folderID: UUID?) {
        guard DatabaseManager.shared.isOpen else { return }
        try? DatabaseManager.shared.run(
            "UPDATE ssh_profiles SET folder_id = ?, updated_at = ? WHERE id = ?;",
            bind: [
                folderID.map { SQLiteValue.text($0.uuidString) } ?? .null,
                .real(Date.now.timeIntervalSince1970),
                .text(id.uuidString),
            ]
        )
    }

    /// 删除连接：移除记录 + 其私钥文件。
    static func delete(_ id: UUID) {
        guard DatabaseManager.shared.isOpen else { return }
        if let profile = load(id: id), let keyFile = profile.privateKeyFileName {
            SSHKeyStorage.delete(fileName: keyFile)
        }
        try? DatabaseManager.shared.run("DELETE FROM ssh_profiles WHERE id = ?;", bind: [.text(id.uuidString)])
    }

    // MARK: - Tree

    /// 一次性把全部文件夹 + 连接在内存组成多级树；文件夹在前、连接在后，各自按名排序。
    static func buildTree() -> [SSHCollectionNode] {
        let folders = allFolders()
        let profiles = allRequests()
        let childFolders = Dictionary(grouping: folders, by: { $0.parentID })
        let childProfiles = Dictionary(grouping: profiles, by: { $0.folderID })

        func node(for folder: SSHFolder) -> SSHCollectionNode {
            let subFolders = (childFolders[folder.id] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { node(for: $0) }
            let subs = (childProfiles[folder.id] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { SSHCollectionNode(id: $0.id, kind: .profile($0), children: nil) }
            let children = subFolders + subs
            return SSHCollectionNode(id: folder.id, kind: .folder(folder), children: children.isEmpty ? nil : children)
        }

        let rootFolders = folders
            .filter { $0.parentID == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { node(for: $0) }
        let rootProfiles = childProfiles[nil, default: []]
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { SSHCollectionNode(id: $0.id, kind: .profile($0), children: nil) }
        return rootFolders + rootProfiles
    }
}
