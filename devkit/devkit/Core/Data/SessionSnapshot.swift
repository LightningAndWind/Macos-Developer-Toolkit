//
//  SessionSnapshot.swift
//  devkit
//
//  会话快照：用于持久化到 SQLite，App 重启后恢复标签集合与分组。
//

import Foundation

/// 序列化到磁盘的标签快照。
struct TabSnapshot: Codable, Identifiable, Hashable {
    var id: UUID
    var toolID: String
    var customTitle: String?
    var groupID: UUID?
    var isPinned: Bool
    var createdAt: Date
    /// 工具自行贡献的内部状态（如 HTTP 请求内容）；由 `DevkitTool.sessionStateData()` 编码。旧快照无此字段 → nil。
    var toolState: Data?
}

/// 序列化到磁盘的分组快照。
struct TabGroupSnapshot: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var colorRaw: String
    var isCollapsed: Bool
}

/// 单个窗口的会话快照。M1 只有一个主窗口，字段设计允许多窗口扩展。
struct WindowSessionSnapshot: Codable, Hashable {
    var windowID: UUID
    var tabs: [TabSnapshot]
    var groups: [TabGroupSnapshot]
    var selectedTabID: UUID?
}

/// 整个 App 的会话快照（v1）。
struct SessionSnapshot: Codable, Hashable {
    static let currentVersion = 1
    var version: Int = SessionSnapshot.currentVersion
    var savedAt: Date = .now
    var windows: [WindowSessionSnapshot]

    static let empty = SessionSnapshot(windows: [])
}

/// 会话持久化存储。
@MainActor
enum SessionStore {
    private static let storageKey = "session.v1"

    /// 保存当前会话；db 未打开时静默返回。
    static func save(_ snapshot: SessionSnapshot) throws {
        guard DatabaseManager.shared.isOpen else { return }
        let data = try JSONEncoder.devkit.encode(snapshot)
        try DatabaseManager.shared.putKV(key: storageKey, value: data)
    }

    static func load() -> SessionSnapshot? {
        guard DatabaseManager.shared.isOpen,
              let data = try? DatabaseManager.shared.getKV(key: storageKey)
        else { return nil }
        return try? JSONDecoder.devkit.decode(SessionSnapshot.self, from: data)
    }

    static func clear() throws {
        guard DatabaseManager.shared.isOpen else { return }
        try DatabaseManager.shared.run("DELETE FROM kv WHERE key = ?;", bind: [.text(storageKey)])
    }
}

private extension JSONEncoder {
    static var devkit: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static var devkit: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
