//
//  HTTPCollectionStore.swift
//  devkit
//
//  M5：HTTP 集合（多级文件夹 + 已保存请求）持久化。
//  复用 DatabaseManager 的 http_folders / http_requests 两张表；db 未打开时静默降级（与 HTTPHistoryStore 一致）。
//

import Foundation

/// 集合存储（仅在主 actor 使用）。
@MainActor
enum HTTPCollectionStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Folders

    /// 新建文件夹；`parentID == nil` 落在根。返回创建后的模型（db 未开启返回 nil）。
    @discardableResult
    static func createFolder(name: String, parentID: UUID?) -> HTTPFolder? {
        guard DatabaseManager.shared.isOpen else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = HTTPFolder(parentID: parentID, name: trimmed.isEmpty ? "未命名文件夹" : trimmed)
        let now = folder.createdAt.timeIntervalSince1970
        try? DatabaseManager.shared.run(
            """
            INSERT INTO http_folders(id, parent_id, name, created_at, updated_at)
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
            "UPDATE http_folders SET name = ?, updated_at = ? WHERE id = ?;",
            bind: [.text(trimmed), .real(Date.now.timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    static func moveFolder(id: UUID, to parentID: UUID?) {
        guard DatabaseManager.shared.isOpen else { return }
        try? DatabaseManager.shared.run(
            "UPDATE http_folders SET parent_id = ?, updated_at = ? WHERE id = ?;",
            bind: [
                parentID.map { SQLiteValue.text($0.uuidString) } ?? .null,
                .real(Date.now.timeIntervalSince1970),
                .text(id.uuidString),
            ]
        )
    }

    /// 删除文件夹：级联删除所有子孙文件夹及其中的请求。
    static func deleteFolder(id: UUID) throws {
        guard DatabaseManager.shared.isOpen else { return }
        let folders = allFolders()
        // BFS 收集自身 + 全部后代 id。
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
            try DatabaseManager.shared.run("DELETE FROM http_requests WHERE folder_id = ?;", bind: [.text(text)])
            try DatabaseManager.shared.run("DELETE FROM http_folders WHERE id = ?;", bind: [.text(text)])
        }
    }

    static func allFolders() -> [HTTPFolder] {
        guard DatabaseManager.shared.isOpen else { return [] }
        var results: [HTTPFolder] = []
        try? DatabaseManager.shared.query(
            "SELECT id, parent_id, name, created_at, updated_at FROM http_folders ORDER BY name COLLATE NOCASE;"
        ) { row in
            guard let id = UUID(uuidString: row.text(0) ?? ""),
                  let name = row.text(2)
            else { return true }
            let parentID = row.text(1).flatMap { UUID(uuidString: $0) }
            results.append(HTTPFolder(id: id,
                                      parentID: parentID,
                                      name: name,
                                      createdAt: Date(timeIntervalSince1970: row.real(3)),
                                      updatedAt: Date(timeIntervalSince1970: row.real(4))))
            return true
        }
        return results
    }

    // MARK: - Requests

    /// 保存请求：存在则整行更新（ON CONFLICT），否则插入。回填 updatedAt。
    /// `request_json` 仅存 `HTTPRequestModel`；id / folder_id / name / 时间戳走独立列（见 decodeRequest）。
    static func save(_ record: HTTPSavedRequest) throws {
        guard DatabaseManager.shared.isOpen else { return }
        var stored = record
        stored.updatedAt = .now
        let data = try encoder.encode(stored.request)
        try DatabaseManager.shared.run(
            """
            INSERT INTO http_requests(id, folder_id, name, created_at, updated_at, request_json)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                folder_id = excluded.folder_id,
                name = excluded.name,
                updated_at = excluded.updated_at,
                request_json = excluded.request_json;
            """,
            bind: [
                .text(stored.id.uuidString),
                stored.folderID.map { SQLiteValue.text($0.uuidString) } ?? .null,
                .text(stored.name),
                .real(stored.createdAt.timeIntervalSince1970),
                .real(stored.updatedAt.timeIntervalSince1970),
                .blob(data),
            ]
        )
    }

    static func load(id: UUID) -> HTTPSavedRequest? {
        guard DatabaseManager.shared.isOpen else { return nil }
        var result: HTTPSavedRequest?
        try? DatabaseManager.shared.query(
            "SELECT id, folder_id, name, created_at, updated_at, request_json FROM http_requests WHERE id = ?;",
            bind: [.text(id.uuidString)]
        ) { row in
            result = decodeRequest(row: row)
            return false
        }
        return result
    }

    static func allRequests() -> [HTTPSavedRequest] {
        guard DatabaseManager.shared.isOpen else { return [] }
        var results: [HTTPSavedRequest] = []
        try? DatabaseManager.shared.query(
            "SELECT id, folder_id, name, created_at, updated_at, request_json FROM http_requests ORDER BY name COLLATE NOCASE;"
        ) { row in
            if let r = decodeRequest(row: row) { results.append(r) }
            return true
        }
        return results
    }

    /// 仅改名（供标签标题双向同步）。
    static func renameRequest(id: UUID, name: String) {
        guard DatabaseManager.shared.isOpen else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? DatabaseManager.shared.run(
            "UPDATE http_requests SET name = ?, updated_at = ? WHERE id = ?;",
            bind: [.text(trimmed), .real(Date.now.timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    static func moveRequest(id: UUID, to folderID: UUID?) {
        guard DatabaseManager.shared.isOpen else { return }
        try? DatabaseManager.shared.run(
            "UPDATE http_requests SET folder_id = ?, updated_at = ? WHERE id = ?;",
            bind: [
                folderID.map { SQLiteValue.text($0.uuidString) } ?? .null,
                .real(Date.now.timeIntervalSince1970),
                .text(id.uuidString),
            ]
        )
    }

    static func deleteRequest(id: UUID) throws {
        guard DatabaseManager.shared.isOpen else { return }
        try DatabaseManager.shared.run("DELETE FROM http_requests WHERE id = ?;", bind: [.text(id.uuidString)])
    }

    // MARK: - Tree

    /// 一次性把全部文件夹 + 请求在内存组成多级树；文件夹在前、请求在后，各自按名排序。
    static func buildTree() -> [HTTPCollectionNode] {
        let folders = allFolders()
        let requests = allRequests()
        let childFolders = Dictionary(grouping: folders, by: { $0.parentID })
        let childRequests = Dictionary(grouping: requests, by: { $0.folderID })

        func node(for folder: HTTPFolder) -> HTTPCollectionNode {
            let subFolders = (childFolders[folder.id] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { node(for: $0) }
            let subs = (childRequests[folder.id] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { HTTPCollectionNode(id: $0.id, kind: .request($0), children: nil) }
            let children = subFolders + subs
            return HTTPCollectionNode(id: folder.id,
                                      kind: .folder(folder),
                                      children: children.isEmpty ? nil : children)
        }

        let rootFolders = folders
            .filter { $0.parentID == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { node(for: $0) }
        let rootRequests = childRequests[nil, default: []]
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { HTTPCollectionNode(id: $0.id, kind: .request($0), children: nil) }
        return rootFolders + rootRequests
    }

    // MARK: - Private

    private static func decodeRequest(row: SQLiteRow) -> HTTPSavedRequest? {
        guard let idText = row.text(0), let id = UUID(uuidString: idText),
              let name = row.text(2),
              let blob = row.blob(5)
        else { return nil }
        // 正常：blob 存 HTTPRequestModel。兼容早期误存整条 HTTPSavedRequest 的记录：回退取其 request。
        // 必须给 try? 加括号，否则 `try? a ?? b` 会被解析为 `try? (a ?? b)`，a 为非可选使回退失效。
        let request = (try? decoder.decode(HTTPRequestModel.self, from: blob))
            ?? decodeLegacyRequest(blob)
        guard let request else { return nil }
        let folderID = row.text(1).flatMap { UUID(uuidString: $0) }
        return HTTPSavedRequest(id: id,
                                folderID: folderID,
                                name: name,
                                request: request,
                                createdAt: Date(timeIntervalSince1970: row.real(3)),
                                updatedAt: Date(timeIntervalSince1970: row.real(4)))
    }

    private static func decodeLegacyRequest(_ blob: Data) -> HTTPRequestModel? {
        guard let legacy = try? decoder.decode(HTTPSavedRequest.self, from: blob) else { return nil }
        return legacy.request
    }
}
