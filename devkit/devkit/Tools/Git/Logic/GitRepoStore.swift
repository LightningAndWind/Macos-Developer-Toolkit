//
//  GitRepoStore.swift
//  devkit
//
//  Git 仓库集合（多级文件夹 + 仓库登记）持久化。逐函数对照 SSHProfileStore：
//  git_folders / git_repos 两表；repo 整条编入 repo_json blob，标量列为查询冗余，解码以 blob 为准。
//  删仓库只删记录，不动密钥文件（密钥是独立一等实体）。
//

import Foundation

@MainActor
enum GitRepoStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Folders

    @discardableResult
    static func createFolder(name: String, parentID: UUID?) -> GitFolder? {
        guard DatabaseManager.shared.isOpen else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = GitFolder(parentID: parentID, name: trimmed.isEmpty ? "未命名文件夹" : trimmed)
        let now = folder.createdAt.timeIntervalSince1970
        try? DatabaseManager.shared.run(
            """
            INSERT INTO git_folders(id, parent_id, name, created_at, updated_at)
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
            "UPDATE git_folders SET name = ?, updated_at = ? WHERE id = ?;",
            bind: [.text(trimmed), .real(Date.now.timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    /// 删除文件夹：级联删除所有子孙文件夹及其中的仓库登记。
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
            for repo in allRepos() where repo.folderID == fid {
                delete(repo.id)
            }
            try? DatabaseManager.shared.run("DELETE FROM git_folders WHERE id = ?;", bind: [.text(text)])
        }
    }

    static func allFolders() -> [GitFolder] {
        guard DatabaseManager.shared.isOpen else { return [] }
        var results: [GitFolder] = []
        try? DatabaseManager.shared.query(
            "SELECT id, parent_id, name, created_at, updated_at FROM git_folders ORDER BY name COLLATE NOCASE;"
        ) { row in
            guard let id = UUID(uuidString: row.text(0) ?? ""),
                  let name = row.text(2)
            else { return true }
            let parentID = row.text(1).flatMap { UUID(uuidString: $0) }
            results.append(GitFolder(id: id,
                                     parentID: parentID,
                                     name: name,
                                     createdAt: Date(timeIntervalSince1970: row.real(3)),
                                     updatedAt: Date(timeIntervalSince1970: row.real(4))))
            return true
        }
        return results
    }

    // MARK: - Repos

    static func save(_ repo: GitRepo) throws {
        guard DatabaseManager.shared.isOpen else { return }
        var stored = repo
        stored.updatedAt = .now
        let data = try encoder.encode(stored)
        try DatabaseManager.shared.run(
            """
            INSERT INTO git_repos(id, folder_id, alias, path, key_id, created_at, updated_at, repo_json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                folder_id = excluded.folder_id,
                alias = excluded.alias,
                path = excluded.path,
                key_id = excluded.key_id,
                updated_at = excluded.updated_at,
                repo_json = excluded.repo_json;
            """,
            bind: [
                .text(stored.id.uuidString),
                stored.folderID.map { SQLiteValue.text($0.uuidString) } ?? .null,
                .text(stored.alias),
                .text(stored.path),
                stored.keyID.map { SQLiteValue.text($0.uuidString) } ?? .null,
                .real(stored.createdAt.timeIntervalSince1970),
                .real(stored.updatedAt.timeIntervalSince1970),
                .blob(data),
            ]
        )
    }

    static func load(id: UUID) -> GitRepo? {
        guard DatabaseManager.shared.isOpen else { return nil }
        var result: GitRepo?
        try? DatabaseManager.shared.query(
            "SELECT repo_json FROM git_repos WHERE id = ?;",
            bind: [.text(id.uuidString)]
        ) { row in
            if let blob = row.blob(0) {
                result = try? decoder.decode(GitRepo.self, from: blob)
            }
            return false
        }
        return result
    }

    static func allRepos() -> [GitRepo] {
        guard DatabaseManager.shared.isOpen else { return [] }
        var results: [GitRepo] = []
        try? DatabaseManager.shared.query(
            "SELECT repo_json FROM git_repos ORDER BY alias COLLATE NOCASE;"
        ) { row in
            if let blob = row.blob(0), let repo = try? decoder.decode(GitRepo.self, from: blob) {
                results.append(repo)
            }
            return true
        }
        return results
    }

    static func renameRepo(id: UUID, alias: String) {
        guard DatabaseManager.shared.isOpen else { return }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? DatabaseManager.shared.run(
            "UPDATE git_repos SET alias = ?, updated_at = ? WHERE id = ?;",
            bind: [.text(trimmed), .real(Date.now.timeIntervalSince1970), .text(id.uuidString)]
        )
        if var repo = load(id: id) {
            repo.alias = trimmed
            try? save(repo)
        }
    }

    static func moveRepo(id: UUID, to folderID: UUID?) {
        guard DatabaseManager.shared.isOpen else { return }
        guard var repo = load(id: id) else { return }
        repo.folderID = folderID
        try? save(repo)
    }

    /// 删除仓库登记：仅移除记录，不动磁盘上的工作目录与密钥。
    static func delete(_ id: UUID) {
        guard DatabaseManager.shared.isOpen else { return }
        try? DatabaseManager.shared.run("DELETE FROM git_repos WHERE id = ?;", bind: [.text(id.uuidString)])
    }

    // MARK: - Tree

    static func buildTree() -> [GitCollectionNode] {
        let folders = allFolders()
        let repos = allRepos()
        let childFolders = Dictionary(grouping: folders, by: { $0.parentID })
        let childRepos = Dictionary(grouping: repos, by: { $0.folderID })

        func node(for folder: GitFolder) -> GitCollectionNode {
            let subFolders = (childFolders[folder.id] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { node(for: $0) }
            let subs = (childRepos[folder.id] ?? [])
                .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
                .map { GitCollectionNode(id: $0.id, kind: .repo($0), children: nil) }
            let children = subFolders + subs
            return GitCollectionNode(id: folder.id, kind: .folder(folder), children: children.isEmpty ? nil : children)
        }

        let rootFolders = folders
            .filter { $0.parentID == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { node(for: $0) }
        let rootRepos = childRepos[nil, default: []]
            .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
            .map { GitCollectionNode(id: $0.id, kind: .repo($0), children: nil) }
        return rootFolders + rootRepos
    }
}
