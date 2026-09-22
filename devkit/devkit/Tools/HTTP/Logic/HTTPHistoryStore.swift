//
//  HTTPHistoryStore.swift
//  devkit
//
//  M2：HTTP 历史记录持久化，复用 DatabaseManager 的 http_history 表。
//  存请求与完整响应快照（方法/url/headers/body/auth + 响应头/响应体）；
//  整体作为 JSON blob 写入 request_json 列，旧记录无 response 键时解码为 nil。
//

import Foundation

/// 一条历史记录。
struct HTTPHistoryRecord: Identifiable, Hashable, Codable {
    var id: UUID
    var timestamp: Date
    var method: String
    var url: String
    var statusCode: Int?
    var durationMs: Int?
    var sizeBytes: Int?
    var request: HTTPRequestModel
    /// 完整响应快照；旧记录或未收到响应时为 nil。
    var response: HTTPResponseSnapshot?
}

/// 历史存储（仅在主 actor 使用；db 未打开时静默降级）。
@MainActor
enum HTTPHistoryStore {
    private static let encoder: JSONEncoder = JSONEncoder()
    private static let decoder: JSONDecoder = JSONDecoder()

    /// 单条历史响应体的存储上限（1 MB）；超出部分截断并标记。
    static let maxBodyBytes = 1_048_576

    /// 记录一次请求（响应快照可选）。
    static func insert(request: HTTPRequestModel, response: HTTPResponseModel?) throws {
        guard DatabaseManager.shared.isOpen else { return }
        let snapshot = response.map { HTTPResponseSnapshot(from: $0, maxBodyBytes: maxBodyBytes) }
        let record = HTTPHistoryRecord(
            id: UUID(),
            timestamp: .now,
            method: request.method,
            url: request.appliedURLString,
            statusCode: response?.statusCode,
            durationMs: response?.durationMs,
            sizeBytes: response?.sizeBytes,
            request: request,
            response: snapshot
        )
        let data = try encoder.encode(record)
        try DatabaseManager.shared.run(
            """
            INSERT INTO http_history(id, created_at, method, url, status_code, duration_ms, size_bytes, request_json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bind: [
                .text(record.id.uuidString),
                .real(record.timestamp.timeIntervalSince1970),
                .text(record.method),
                .text(record.url),
                record.statusCode.map { SQLiteValue.int($0) } ?? .null,
                record.durationMs.map { SQLiteValue.int($0) } ?? .null,
                record.sizeBytes.map { SQLiteValue.int($0) } ?? .null,
                .blob(data),
            ]
        )
    }

    /// 最近历史（默认 100 条）。
    static func recent(limit: Int = 100) -> [HTTPHistoryRecord] {
        fetch(sql: "SELECT request_json FROM http_history ORDER BY created_at DESC LIMIT ?;",
              bind: [.int(limit)])
    }

    /// 按 method / url 关键字搜索。空查询返回最近历史。
    static func search(_ query: String) -> [HTTPHistoryRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recent() }
        let pattern = "%\(trimmed)%"
        return fetch(
            sql: "SELECT request_json FROM http_history WHERE url LIKE ? OR method LIKE ? ORDER BY created_at DESC LIMIT 200;",
            bind: [.text(pattern), .text(pattern)]
        )
    }

    static func delete(id: UUID) throws {
        guard DatabaseManager.shared.isOpen else { return }
        try DatabaseManager.shared.run("DELETE FROM http_history WHERE id = ?;", bind: [.text(id.uuidString)])
    }

    static func clearAll() throws {
        guard DatabaseManager.shared.isOpen else { return }
        try DatabaseManager.shared.run("DELETE FROM http_history;")
    }

    // MARK: - Private

    private static func fetch(sql: String, bind: [SQLiteValue]) -> [HTTPHistoryRecord] {
        guard DatabaseManager.shared.isOpen else { return [] }
        var results: [HTTPHistoryRecord] = []
        try? DatabaseManager.shared.query(sql, bind: bind) { row in
            if let blob = row.blob(0),
               let record = try? decoder.decode(HTTPHistoryRecord.self, from: blob) {
                results.append(record)
            }
            return true
        }
        return results
    }
}
