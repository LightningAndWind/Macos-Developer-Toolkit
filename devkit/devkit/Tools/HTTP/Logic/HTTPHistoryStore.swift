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
    /// 发出此历史的已保存记录 ID；从未保存的请求发出时为 nil。
    /// 删除某条已保存请求时据此精确清掉“它自己发出的”历史。
    var savedRequestID: UUID?
}

/// 管理列表用的历史摘要：只含标量列。
///
/// 与 `HTTPHistoryRecord` 的区别是**不读 `request_json` blob**（其中可能含最大 1 MB 的响应体）。
/// 设置面板等「只需展示与删除」的场景用它，避免为列几百条历史把响应体全解进内存。
struct HTTPHistorySummary: Identifiable, Hashable {
    var id: UUID
    var timestamp: Date
    var method: String
    var url: String
    var statusCode: Int?
}

/// 历史存储（仅在主 actor 使用；db 未打开时静默降级）。
@MainActor
enum HTTPHistoryStore {
    private static let encoder: JSONEncoder = JSONEncoder()
    private static let decoder: JSONDecoder = JSONDecoder()

    /// 单条历史响应体的存储上限（1 MB）；超出部分截断并标记。
    ///
    /// **用十进制整数（1_000_000）而不是 `1 * 1_048_576`**：详情页会把这个值经
    /// `HTTPDisplay.size`（`ByteCountFormatter(countStyle: .file)`，十进制口径）渲染成
    /// 「仅保存前 1 MB」。写成 1 MiB 的话界面上会显示「1.0 MB」，与文档对不上。
    static let maxBodyBytes = 1_000_000

    /// 记录一次请求（响应快照可选）。
    ///
    /// 注意 `size_bytes` 列存的是**实际收到的字节数**：响应体超过 `HTTPClient.maxBodyBytes`
    /// 时接收会被中止，这里记的就是上限值而非服务器声明的完整长度。
    /// 是否被截断由快照里的 `isBodyTruncated` 表达，展示时需加「≥」前缀。
    static func insert(request: HTTPRequestModel, response: HTTPResponseModel?, savedRequestID: UUID? = nil) throws {
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
            response: snapshot,
            savedRequestID: savedRequestID
        )
        let data = try encoder.encode(record)
        try DatabaseManager.shared.run(
            """
            INSERT INTO http_history(id, created_at, method, url, status_code, duration_ms, size_bytes, saved_request_id, request_json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bind: [
                .text(record.id.uuidString),
                .real(record.timestamp.timeIntervalSince1970),
                .text(record.method),
                .text(record.url),
                record.statusCode.map { SQLiteValue.int($0) } ?? .null,
                record.durationMs.map { SQLiteValue.int($0) } ?? .null,
                record.sizeBytes.map { SQLiteValue.int($0) } ?? .null,
                savedRequestID.map { SQLiteValue.text($0.uuidString) } ?? .null,
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

    /// 最近历史的轻量摘要（不加载 `request_json`）。供设置面板等管理列表使用。
    static func recentSummaries(limit: Int = 300) -> [HTTPHistorySummary] {
        guard DatabaseManager.shared.isOpen else { return [] }
        var results: [HTTPHistorySummary] = []
        try? DatabaseManager.shared.query(
            "SELECT id, created_at, method, url, status_code FROM http_history ORDER BY created_at DESC LIMIT ?;",
            bind: [.int(limit)]
        ) { row in
            guard let id = UUID(uuidString: row.text(0) ?? "") else { return true }
            results.append(HTTPHistorySummary(
                id: id,
                timestamp: Date(timeIntervalSince1970: row.real(1)),
                method: row.text(2) ?? "",
                url: row.text(3) ?? "",
                statusCode: row.intOrNil(4)
            ))
            return true
        }
        return results
    }

    /// 历史总条数（管理列表用，避免为了计数而取数据）。
    static func count() -> Int {
        guard DatabaseManager.shared.isOpen else { return 0 }
        var total = 0
        try? DatabaseManager.shared.query("SELECT COUNT(*) FROM http_history;") { row in
            total = row.int(0)
            return false
        }
        return total
    }

    static func delete(id: UUID) throws {
        guard DatabaseManager.shared.isOpen else { return }
        try DatabaseManager.shared.run("DELETE FROM http_history WHERE id = ?;", bind: [.text(id.uuidString)])
    }

    /// 删除某条已保存记录“自身发出”的历史（按 `saved_request_id` 外键匹配）。命中 `idx_history_saved`。
    ///
    /// 用于「删除已保存请求时连带清掉它的历史」：只删发送时绑定过该记录的条目，
    /// 不误伤同 URL/方法的其它来源历史。返回删除条数（供调用方判断是否需刷新标签历史）。
    @discardableResult
    static func deleteForSavedRequest(_ id: UUID) -> Int {
        guard DatabaseManager.shared.isOpen else { return 0 }
        var removed = 0
        try? DatabaseManager.shared.query(
            "SELECT id FROM http_history WHERE saved_request_id = ?;",
            bind: [.text(id.uuidString)]
        ) { _ in removed += 1; return true }
        guard removed > 0 else { return 0 }
        try? DatabaseManager.shared.run(
            "DELETE FROM http_history WHERE saved_request_id = ?;",
            bind: [.text(id.uuidString)]
        )
        return removed
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
