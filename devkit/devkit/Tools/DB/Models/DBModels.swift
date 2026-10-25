//
//  DBModels.swift
//  devkit
//
//  数据库连接记录的数据模型（MySQL / Redis），组织方式对照 SSHProfile：
//  整条以 Codable 编入 `db_connections.conn_json`，标量列仅作查询冗余。
//  凭据（密码）明文随记录存入 SQLite，与既有 SSH 记录的安全模型一致；
//  AI 接入（MCP）侧只暴露别名与 ID，且 host/用户名/密码会进 Redactor 脱敏集合。
//

import Foundation

/// 数据库类型。
enum DBConnectionKind: String, CaseIterable, Codable, Hashable {
    case mysql
    case redis

    var label: String {
        switch self {
        case .mysql: return "MySQL"
        case .redis: return "Redis"
        }
    }

    var defaultPort: Int {
        switch self {
        case .mysql: return 3306
        case .redis: return 6379
        }
    }
}

/// 一条数据库连接记录。
struct DBConnection: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var kind: DBConnectionKind = .mysql
    var host: String = ""
    var port: Int = 3306
    /// MySQL 用户名；Redis 6+ ACL 用户名（默认用户可留空）。
    var username: String?
    /// MySQL 密码 / Redis requirepass（或 ACL 用户密码）。
    var password: String?
    /// MySQL：默认库名；Redis：db 序号（"0"-"15"）。
    var database: String?
    var createdAt: Date = .now
    var updatedAt: Date = .now

    // MARK: - 派生

    var normalizedUsername: String? {
        guard let u = username?.trimmingCharacters(in: .whitespaces), !u.isEmpty else { return nil }
        return u
    }

    var normalizedPassword: String? {
        guard let p = password, !p.isEmpty else { return nil }
        return p
    }

    var normalizedDatabase: String? {
        guard let d = database?.trimmingCharacters(in: .whitespaces), !d.isEmpty else { return nil }
        return d
    }

    /// 展示用摘要（不含主机——本模型在界面内展示 host 无妨，但保持与 SSH 记录一致的习惯：
    /// 摘要只放非敏感的类型与库信息）。
    var displaySummary: String {
        switch kind {
        case .mysql:
            return normalizedDatabase.map { "MySQL · \($0)" } ?? "MySQL"
        case .redis:
            return normalizedDatabase.map { "Redis · db\($0)" } ?? "Redis"
        }
    }
}

/// 一次数据库执行的统一结果（文本渲染，命令行风格）。
struct DBExecResult: Sendable {
    /// SQL / 命令是否成功执行（错误以 errorText 描述）。
    var ok: Bool
    /// redis-cli / TSV 风格的渲染文本。
    var text: String
    /// 失败原因（已渲染为可读文本）。
    var errorText: String?
    /// 输出超过上限被截断。
    var truncated: Bool
}

/// 数据库执行错误。
enum DBExecError: LocalizedError {
    case badDatabaseField(String)
    case redisProtocolError(String)
    case queryTimeout
    case connectFailed(String)
    /// 底层 IO 错误（文案已可读，原样返回，不再加「连接失败：」前缀）。
    case ioFailed(String)

    var errorDescription: String? {
        switch self {
        case .badDatabaseField(let m): return m
        case .redisProtocolError(let m): return "Redis 协议错误：\(m)"
        case .queryTimeout: return "执行超时，连接已断开"
        case .connectFailed(let m): return "连接失败：\(m)"
        case .ioFailed(let m): return m
        }
    }
}
