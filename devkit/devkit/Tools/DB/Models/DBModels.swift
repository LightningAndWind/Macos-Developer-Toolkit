//
//  DBModels.swift
//  devkit
//
//  数据库连接记录的数据模型（MySQL / Redis），组织方式对照 SSHProfile：
//  整条以 Codable 编入 `db_connections.conn_json`，标量列仅作查询冗余。
//  凭据（密码）明文随记录存入 SQLite，与既有 SSH 记录的安全模型一致；
//  AI 接入（MCP）侧按记录的 mcpEnabled / mcpRedactionEnabled 决定可见性与脱敏：
//  默认只暴露别名与 ID（host/用户名进 Redactor 脱敏集合），关闭脱敏才返回连接信息；密码永不输出。
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
    /// 该连接是否由 MCP（AI 接入）提供：关闭后 db_list_connections 不返回它，
    /// 且按 id / 名称直接调用 db_query / db_command 也会被当作不存在。
    var mcpEnabled: Bool = true
    /// 该连接经 MCP 输出时是否脱敏：开启（默认）则 host / 用户名进入脱敏集合、列表不返回连接信息；
    /// 关闭则列表额外返回 host / 端口 / 用户名，且这些值可出现在其它 MCP 输出中。密码永不输出。
    var mcpRedactionEnabled: Bool = true
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

// MARK: - 兼容旧数据的解码

extension DBConnection {
    /// 自定义解码（放在扩展里，保留编译器合成的逐成员初始化器），模式对照 SSHProfile：
    /// 后补字段 `mcpEnabled` / `mcpRedactionEnabled` 旧数据 JSON 里没有，
    /// 走 `decodeIfPresent` 兜底默认值，避免旧连接被 `try?` 吞掉后在界面上静默消失。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(DBConnectionKind.self, forKey: .kind) ?? .mysql
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        database = try c.decodeIfPresent(String.self, forKey: .database)
        mcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? true
        mcpRedactionEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpRedactionEnabled) ?? true
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
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
        case .redisProtocolError(let m): return String(format: L("Redis 协议错误：%@"), String(m))
        case .queryTimeout: return L("执行超时，连接已断开")
        case .connectFailed(let m): return String(format: L("连接失败：%@"), String(m))
        case .ioFailed(let m): return m
        }
    }
}
