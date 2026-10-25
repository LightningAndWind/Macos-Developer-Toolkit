//
//  MCPToolCatalog.swift
//  devkit
//
//  AI 接入对外暴露的工具目录与分发：SSH 4 个（列表 / 开会话 / 执行 / 关会话）+
//  Git 3 个（仓库列表 / 状态 / 执行）。安全约定：
//  - 模型只拿得到「服务器别名 / ID」「仓库别名 / ID」，凭据（IP、用户名、密码、密钥路径）
//    在本层内部经 SSHProfileStore / GitSSHBridge 取用，绝不出现在参数、结果与错误文本里；
//  - 一切出站文本（含错误消息）都过 Redactor；
//  - 每次调用记入 AIAccessServer 审计日志。
//

import Foundation

/// 工具层的用户可读错误（消息会脱敏后返回给模型）。
struct MCPToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class MCPToolCatalog {
    static let shared = MCPToolCatalog()

    struct Definition {
        let name: String
        let description: String
        let inputSchema: MCPJSON
    }

    struct CallOutcome: Sendable {
        let text: String
        let isError: Bool
    }

    let definitions: [Definition] = [
        Definition(
            name: "ssh_list_servers",
            description: "列出 devkit 中已保存的远程服务器（id、名称别名、认证方式、默认工作目录），以及当前打开的持久会话列表。出于安全考虑不返回 IP、用户名、端口等任何连接信息；后续工具用 id 或名称引用服务器。",
            inputSchema: MCPToolCatalog.schema(properties: [:])),
        Definition(
            name: "ssh_open_session",
            description: "打开到指定服务器的持久 SSH 会话。会话保持真实 shell 状态：cd、环境变量、venv 激活等跨命令保留。cwd 可选（会话起始目录，不存在会报错）。会话空闲 30 分钟或存活满 2 小时会被自动回收；并发上限 8 个。",
            inputSchema: MCPToolCatalog.schema(properties: [
                "server": .object(["type": .string("string"),
                                   "description": .string("服务器 id 或名称（来自 ssh_list_servers）")]),
                "cwd": .object(["type": .string("string"),
                                "description": .string("会话起始目录（可选）")]),
            ], required: ["server"])),
        Definition(
            name: "ssh_exec",
            description: "在远程服务器上执行 shell 命令并返回 exitCode / stdout / stderr。两种方式二选一：传 session（持久会话，状态保留）或传 server（一次性执行，独立连接，cwd 仅此模式可用）。命令应是完整的多行脚本（heredoc 等吞行的写法需自行收尾）。默认超时 30 秒（timeoutSeconds 可调 5-600）：一次性执行超时仅返回部分输出；持久会话超时会被关闭，需重新 ssh_open_session。远端登录 shell 需为 POSIX 系（bash/sh/zsh/ksh 等）。单流输出超 512KB 截断。任何凭据都不会提供，输出中的 [REDACTED] 为脱敏占位符。",
            inputSchema: MCPToolCatalog.schema(properties: [
                "session": .object(["type": .string("string"),
                                    "description": .string("持久会话 id（与 server 二选一）")]),
                "server": .object(["type": .string("string"),
                                   "description": .string("服务器 id 或名称，一次性执行（与 session 二选一）")]),
                "command": .object(["type": .string("string"),
                                    "description": .string("要执行的 shell 命令 / 多行脚本")]),
                "cwd": .object(["type": .string("string"),
                                "description": .string("一次性执行的工作目录（可选；持久会话模式不支持）")]),
                "timeoutSeconds": .object(["type": .string("number"),
                                           "description": .string("超时秒数，5-600，默认 30（可选）")]),
            ], required: ["command"])),
        Definition(
            name: "ssh_close_session",
            description: "关闭一个持久 SSH 会话（幂等）。",
            inputSchema: MCPToolCatalog.schema(properties: [
                "session": .object(["type": .string("string"),
                                    "description": .string("会话 id")]),
            ], required: ["session"])),
        Definition(
            name: "git_list_repos",
            description: "列出 devkit 中登记的本地 Git 仓库（id、别名、本地路径、是否绑定了 SSH 密钥）。",
            inputSchema: MCPToolCatalog.schema(properties: [:])),
        Definition(
            name: "git_status",
            description: "查看某仓库的工作区状态：当前分支、上游、ahead/behind、变更文件列表、是否变基中。",
            inputSchema: MCPToolCatalog.schema(properties: [
                "repo": .object(["type": .string("string"),
                                 "description": .string("仓库 id 或别名（来自 git_list_repos）")]),
            ], required: ["repo"])),
        Definition(
            name: "git_run",
            description: "在指定仓库目录执行 git 子命令，args 为参数数组（如 [\"pull\"]、[\"log\", \"-n\", \"20\"]、[\"commit\", \"-m\", \"…\"]）。绑定了密钥的仓库，fetch/pull/push 等远程操作会自动使用 devkit 内保存的密钥认证，无需也不提供任何凭据。默认超时 30 秒（timeoutSeconds 可调 5-600）。",
            inputSchema: MCPToolCatalog.schema(properties: [
                "repo": .object(["type": .string("string"),
                                 "description": .string("仓库 id 或别名")]),
                "args": .object(["type": .string("array"),
                                 "items": .object(["type": .string("string")]),
                                 "description": .string("git 参数数组，不含 git 本身")]),
                "timeoutSeconds": .object(["type": .string("number"),
                                           "description": .string("超时秒数，5-600，默认 30（可选）")]),
            ], required: ["repo", "args"])),
        Definition(
            name: "db_list_connections",
            description: "列出 devkit 中已保存的数据库连接（MySQL / Redis：id、名称、类型、默认库）。出于安全考虑不返回主机、用户名等连接信息；后续工具用 id 或名称引用连接。",
            inputSchema: MCPToolCatalog.schema(properties: [:])),
        Definition(
            name: "db_query",
            description: "在指定 MySQL 连接上执行 SQL 并返回表格文本（TSV，NULL 显示为 NULL；无结果集返回 OK）。可多语句，返回最后一条的结果集。默认超时 30 秒（timeoutSeconds 可调 5-600）。仅支持 MySQL 连接；Redis 用 db_command。",
            inputSchema: MCPToolCatalog.schema(properties: [
                "connection": .object(["type": .string("string"),
                                       "description": .string("连接 id 或名称（来自 db_list_connections）")]),
                "sql": .object(["type": .string("string"),
                                "description": .string("要执行的 SQL（可多语句，分号分隔）")]),
                "timeoutSeconds": .object(["type": .string("number"),
                                           "description": .string("超时秒数，5-600，默认 30（可选）")]),
            ], required: ["connection", "sql"])),
        Definition(
            name: "db_command",
            description: "在指定 Redis 连接上执行命令并返回 redis-cli 风格文本。command 为命令行式字符串，每行一条命令（如 \"SET key value\\nGET key\"），参数含空格用引号包裹。连接配置的密码与 db 号会自动应用（AUTH/SELECT）。默认超时 30 秒（timeoutSeconds 可调 5-600）。仅支持 Redis 连接；MySQL 用 db_query。",
            inputSchema: MCPToolCatalog.schema(properties: [
                "connection": .object(["type": .string("string"),
                                       "description": .string("连接 id 或名称（来自 db_list_connections）")]),
                "command": .object(["type": .string("string"),
                                    "description": .string("Redis 命令，每行一条")]),
                "timeoutSeconds": .object(["type": .string("number"),
                                           "description": .string("超时秒数，5-600，默认 30（可选）")]),
            ], required: ["connection", "command"])),
    ]

    var definitionsJSON: [MCPJSON] {
        definitions.map {
            .object([
                "name": .string($0.name),
                "description": .string($0.description),
                "inputSchema": $0.inputSchema,
            ])
        }
    }

    // MARK: - 分发

    func call(name: String, arguments: MCPJSON) async -> CallOutcome {
        let args = arguments.objectValue ?? [:]
        let started = Date()
        do {
            let outcome = try await dispatch(name: name, args: args)
            AIAccessServer.shared.recordAudit(tool: name, summary: outcome.summary,
                                              ok: !outcome.isError,
                                              durationMS: Int(Date().timeIntervalSince(started) * 1000))
            return CallOutcome(text: outcome.text, isError: outcome.isError)
        } catch {
            let message = Redactor.redact(error.localizedDescription)
            AIAccessServer.shared.recordAudit(tool: name, summary: argSummary(name, args),
                                              ok: false,
                                              durationMS: Int(Date().timeIntervalSince(started) * 1000))
            return CallOutcome(text: message, isError: true)
        }
    }

    private struct DispatchOutcome {
        let text: String
        let isError: Bool
        let summary: String
    }

    private func dispatch(name: String, args: [String: MCPJSON]) async throws -> DispatchOutcome {
        switch name {
        case "ssh_list_servers": return try await listServers(args)
        case "ssh_open_session": return try await openSession(args)
        case "ssh_exec": return try await exec(args)
        case "ssh_close_session": return try await closeSession(args)
        case "git_list_repos": return try await listRepos(args)
        case "git_status": return try await gitStatus(args)
        case "git_run": return try await gitRun(args)
        case "db_list_connections": return try await listDBConnections(args)
        case "db_query": return try await dbQuery(args)
        case "db_command": return try await dbCommand(args)
        default: throw MCPToolError(message: "未知工具：\(name)。可用工具见 tools/list。")
        }
    }

    // MARK: - SSH 工具

    private func listServers(_ args: [String: MCPJSON]) async throws -> DispatchOutcome {
        let servers: [MCPJSON] = SSHProfileStore.allRequests()
            .filter { $0.isRemote }
            .map { p in
                .object([
                    "id": .string(p.id.uuidString),
                    "name": .string(p.name),
                    "authKind": .string(p.authKind.rawValue),
                    "defaultWorkingDirectory": p.normalizedWorkingDirectory
                        .map { .string(Redactor.redact($0)) } ?? .null,
                ])
            }
        let sessions: [MCPJSON] = SSHSessionRegistry.shared.summaries.map { s in
            .object([
                "sessionId": .string(s.sessionId.uuidString),
                "server": .string(s.server),
                "authKind": .string(s.authKind),
                "idleSeconds": .int(Int64(s.idleSeconds)),
            ])
        }
        let result = MCPJSON.object(["servers": .array(servers), "activeSessions": .array(sessions)])
        return DispatchOutcome(text: result.encoded(), isError: false, summary: "共 \(servers.count) 台服务器")
    }

    private func openSession(_ args: [String: MCPJSON]) async throws -> DispatchOutcome {
        let profile = try resolveProfile(args["server"]?.stringValue)
        let cwd = args["cwd"]?.stringValue
        let id = try await SSHSessionRegistry.shared.openSession(profile: profile, cwd: cwd)
        let result = MCPJSON.object([
            "sessionId": .string(id.uuidString),
            "server": .string(profile.name),
            "note": .string("会话保持 shell 状态；空闲 30 分钟或满 2 小时自动回收，超时也会被关闭，届时请重新开会话"),
        ])
        return DispatchOutcome(text: result.encoded(), isError: false,
                               summary: "server=\(profile.name)")
    }

    private func exec(_ args: [String: MCPJSON]) async throws -> DispatchOutcome {
        guard let command = args["command"]?.stringValue, !command.isEmpty else {
            throw MCPToolError(message: "缺少 command 参数")
        }
        let sessionRef = args["session"]?.stringValue
        let serverRef = args["server"]?.stringValue
        let timeout = SSHSessionRegistry.clampTimeout(args["timeoutSeconds"]?.doubleValue)

        let result: SSHExecResult
        let summaryCommand = Redactor.redact(command.prefix(160).description)
        if let sessionRef {
            if serverRef != nil {
                throw MCPToolError(message: "session 与 server 二选一")
            }
            if args["cwd"] != nil {
                throw MCPToolError(message: "持久会话模式不支持 cwd，请在命令里自行 cd")
            }
            guard let sessionID = UUID(uuidString: sessionRef) else {
                throw MCPToolError(message: "session 不是合法的会话 id")
            }
            result = try await SSHSessionRegistry.shared.exec(sessionID: sessionID,
                                                              command: command, timeout: timeout)
        } else if let serverRef {
            let profile = try resolveProfile(serverRef)
            let cwd = args["cwd"]?.stringValue
            result = try await SSHSessionRegistry.shared.execOneShot(profile: profile,
                                                                     command: command,
                                                                     cwd: cwd, timeout: timeout)
        } else {
            throw MCPToolError(message: "session 与 server 必须二选一")
        }

        // shell 带着退出码退出（如命令以 exit 结束）不算调用失败，模型读 exitCode 即可；
        // 无退出码的退出（断线 / ssh 报错）与超时才算。
        let isError = result.timedOut || (result.shellExited && result.exitCode == nil)
        let json = MCPJSON.object([
            "exitCode": result.exitCode.map { MCPJSON.int(Int64($0)) } ?? .null,
            "stdout": .string(Redactor.redact(result.stdoutText)),
            "stderr": .string(Redactor.redact(result.stderrText)),
            "truncated": .bool(result.truncated),
            "timedOut": .bool(result.timedOut),
            "shellExited": .bool(result.shellExited),
        ])
        return DispatchOutcome(text: json.encoded(), isError: isError,
                               summary: (sessionRef.map { "session=\($0.prefix(8))…" } ?? "server=一次性") +
                                   " cmd=\(summaryCommand)")
    }

    private func closeSession(_ args: [String: MCPJSON]) async throws -> DispatchOutcome {
        guard let ref = args["session"]?.stringValue, let id = UUID(uuidString: ref) else {
            throw MCPToolError(message: "缺少合法的 session 参数")
        }
        await SSHSessionRegistry.shared.close(sessionID: id)
        return DispatchOutcome(text: MCPJSON.object(["closed": .bool(true)]).encoded(),
                               isError: false, summary: "session=\(ref.prefix(8))…")
    }

    // MARK: - Git 工具

    private func listRepos(_ args: [String: MCPJSON]) async throws -> DispatchOutcome {
        let repos: [MCPJSON] = GitRepoStore.allRepos().map { r in
            .object([
                "id": .string(r.id.uuidString),
                "alias": .string(r.alias),
                "path": .string(r.path),
                "hasBoundKey": .bool(r.keyID != nil),
            ])
        }
        let result = MCPJSON.object(["repos": .array(repos)])
        return DispatchOutcome(text: Redactor.redact(result.encoded()), isError: false,
                               summary: "共 \(repos.count) 个仓库")
    }

    private func gitStatus(_ args: [String: MCPJSON]) async throws -> DispatchOutcome {
        let repo = try resolveRepo(args["repo"]?.stringValue)
        let repository = GitRepository(repo: repo)
        let status = try await repository.status()
        let entries: [MCPJSON] = status.entries.map { e in
            .object([
                "status": .string(e.xy),
                "path": .string(e.path),
                "fromPath": e.fromPath.map { .string($0) } ?? .null,
            ])
        }
        let result = MCPJSON.object([
            "branch": .string(status.branch),
            "upstream": status.upstream.map { .string($0) } ?? .null,
            "ahead": .int(Int64(status.ahead)),
            "behind": .int(Int64(status.behind)),
            "isRebasing": .bool(status.isRebasing),
            "entries": .array(entries),
        ])
        return DispatchOutcome(text: Redactor.redact(result.encoded()), isError: false,
                               summary: "repo=\(repo.alias)")
    }

    private func gitRun(_ args: [String: MCPJSON]) async throws -> DispatchOutcome {
        let repo = try resolveRepo(args["repo"]?.stringValue)
        guard let rawArgs = args["args"]?.arrayValue, !rawArgs.isEmpty else {
            throw MCPToolError(message: "缺少 args 参数（git 参数数组）")
        }
        let gitArgs = rawArgs.compactMap { $0.stringValue }
        if gitArgs.count != rawArgs.count {
            throw MCPToolError(message: "args 数组内必须全部是字符串")
        }
        let timeout = SSHSessionRegistry.clampTimeout(args["timeoutSeconds"]?.doubleValue)
        let environment = GitSSHBridge.environment(keyID: repo.keyID)
        let out = try await GitRunner.git(gitArgs, at: repo.path,
                                          environment: environment, timeout: timeout)
        let result = MCPJSON.object([
            "exitCode": .int(Int64(out.exitCode)),
            "stdout": .string(Redactor.redact(out.stdout)),
            "stderr": .string(Redactor.redact(out.stderr)),
            "timedOut": .bool(out.timedOut),
        ])
        return DispatchOutcome(text: result.encoded(), isError: out.timedOut,
                               summary: "repo=\(repo.alias) git \(Redactor.redact(String(gitArgs.joined(separator: " ").prefix(120))))")
    }

    // MARK: - 数据库工具

    private func listDBConnections(_ args: [String: MCPJSON]) async throws -> DispatchOutcome {
        let connections: [MCPJSON] = DBConnectionStore.all().map { c in
            .object([
                "id": .string(c.id.uuidString),
                "name": .string(c.name),
                "kind": .string(c.kind.rawValue),
                "defaultDatabase": c.normalizedDatabase.map { .string($0) } ?? .null,
            ])
        }
        let result = MCPJSON.object(["connections": .array(connections)])
        return DispatchOutcome(text: result.encoded(), isError: false,
                               summary: "共 \(connections.count) 个数据库连接")
    }

    private func dbQuery(_ args: [String: MCPJSON]) async throws -> DispatchOutcome {
        guard let sql = args["sql"]?.stringValue, !sql.isEmpty else {
            throw MCPToolError(message: "缺少 sql 参数")
        }
        let connection = try resolveDBConnection(args["connection"]?.stringValue)
        guard connection.kind == .mysql else {
            throw MCPToolError(message: "连接「\(connection.name)」是 Redis 连接；SQL 请用 db_query 的 MySQL 连接，Redis 命令请用 db_command")
        }
        let timeout = DBExec.clampTimeout(args["timeoutSeconds"]?.doubleValue)
        let result = try await DBExec.runMySQL(host: connection.host, port: connection.port,
                                               username: connection.normalizedUsername ?? "root",
                                               password: connection.normalizedPassword,
                                               database: connection.normalizedDatabase,
                                               sql: sql, timeout: timeout)
        var text = Redactor.redact(result.text)
        if result.truncated { text += "\n…（输出过长已截断）" }
        return DispatchOutcome(text: text, isError: false,
                               summary: "db=\(connection.name) sql=\(Redactor.redact(String(sql.prefix(120))))")
    }

    private func dbCommand(_ args: [String: MCPJSON]) async throws -> DispatchOutcome {
        guard let command = args["command"]?.stringValue, !command.isEmpty else {
            throw MCPToolError(message: "缺少 command 参数")
        }
        let connection = try resolveDBConnection(args["connection"]?.stringValue)
        guard connection.kind == .redis else {
            throw MCPToolError(message: "连接「\(connection.name)」是 MySQL 连接；Redis 命令请用 db_command 的 Redis 连接，SQL 请用 db_query")
        }
        let timeout = DBExec.clampTimeout(args["timeoutSeconds"]?.doubleValue)
        let result = try await DBExec.runRedis(host: connection.host, port: connection.port,
                                               username: connection.normalizedUsername,
                                               password: connection.normalizedPassword,
                                               database: connection.normalizedDatabase,
                                               commandText: command, timeout: timeout)
        var text = Redactor.redact(result.text)
        if result.truncated { text += "\n…（输出过长已截断）" }
        return DispatchOutcome(text: text, isError: false,
                               summary: "db=\(connection.name) cmd=\(Redactor.redact(String(command.prefix(120))))")
    }

    // MARK: - 解析与辅助
    /// 按 UUID 精确匹配，再按名称（精确 → 忽略大小写）匹配；仅接受远程记录。
    private func resolveProfile(_ ref: String?) throws -> SSHProfile {
        guard let ref, !ref.isEmpty else { throw MCPToolError(message: "缺少 server 参数") }
        let all = SSHProfileStore.allRequests().filter { $0.isRemote }
        if let id = UUID(uuidString: ref), let p = all.first(where: { $0.id == id }) {
            return p
        }
        if let p = all.first(where: { $0.name == ref }) { return p }
        if let p = all.first(where: { $0.name.lowercased() == ref.lowercased() }) { return p }
        throw MCPToolError(message: "找不到服务器「\(ref)」；请先 ssh_list_servers 查看可用服务器")
    }

    private func resolveRepo(_ ref: String?) throws -> GitRepo {
        guard let ref, !ref.isEmpty else { throw MCPToolError(message: "缺少 repo 参数") }
        let all = GitRepoStore.allRepos()
        if let id = UUID(uuidString: ref), let r = all.first(where: { $0.id == id }) {
            return r
        }
        if let r = all.first(where: { $0.alias == ref }) { return r }
        if let r = all.first(where: { $0.alias.lowercased() == ref.lowercased() }) { return r }
        throw MCPToolError(message: "找不到仓库「\(ref)」；请先 git_list_repos 查看已登记的仓库")
    }

    /// 按 UUID 精确匹配，再按名称（精确 → 忽略大小写）匹配。
    private func resolveDBConnection(_ ref: String?) throws -> DBConnection {
        guard let ref, !ref.isEmpty else { throw MCPToolError(message: "缺少 connection 参数") }
        let all = DBConnectionStore.all()
        if let id = UUID(uuidString: ref), let c = all.first(where: { $0.id == id }) {
            return c
        }
        if let c = all.first(where: { $0.name == ref }) { return c }
        if let c = all.first(where: { $0.name.lowercased() == ref.lowercased() }) { return c }
        throw MCPToolError(message: "找不到数据库连接「\(ref)」；请先 db_list_connections 查看可用连接")
    }

    private func argSummary(_ name: String, _ args: [String: MCPJSON]) -> String {
        let redacted = args.mapValues { Redactor.redact($0.encoded()) }
        let compact = redacted.map { "\($0)=\($1.prefix(120))" }.joined(separator: " ")
        return "\(name) \(compact)"
    }

    private static func schema(properties: [String: MCPJSON], required: [String] = []) -> MCPJSON {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }
}
