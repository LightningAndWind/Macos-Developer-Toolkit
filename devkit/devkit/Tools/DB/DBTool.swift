//
//  DBTool.swift
//  devkit
//
//  M6：数据库工具（MySQL / Redis）。命令行式控制台：选一条已保存连接，输入 SQL / Redis
//  命令（多行 = 多条），⌘↩ 执行，输出按方向着色滚动展示。执行引擎见 DBExecService
//  （无状态单次执行：连接 → 认证 → 执行 → 断开）。应用内控制台与 AI 接入（MCP）共用引擎。
//

import Foundation
import MySQLNIO
import SwiftUI

/// 一条输出条目。
struct DBOutputEntry: Identifiable {
    enum Direction {
        /// 用户输入（回显）。
        case input
        /// 执行结果。
        case output
        /// 错误。
        case error
        /// 提示信息（连接上下文等）。
        case info
    }

    let id = UUID()
    let time = Date()
    let direction: Direction
    let text: String
}

/// 数据库工具实例（一个标签一份）。
@Observable
final class DBTool: DevkitTool {
    static let descriptor = ToolDescriptor(
        id: "tool.db",
        title: "数据库",
        symbolName: "cylinder.and.ellipse",
        category: .network,
        subtitle: "连接 MySQL / Redis，命令行式执行 SQL 与命令，也可供 AI 通过本地接口使用。",
        allowsMultipleInstances: true,
        supportsWindowDetach: true
    )

    var descriptor: ToolDescriptor { Self.descriptor }

    // MARK: - 状态

    /// 连接列表快照（打开标签 / 增删改后刷新）。
    private(set) var connections: [DBConnection] = []
    /// 当前选中的连接。
    var selectedConnectionID: UUID?
    /// 输出历史（仅本标签内存，不持久化）。
    private(set) var output: [DBOutputEntry] = []
    /// 输入草稿（随会话快照持久化）。
    var inputText = ""
    /// 是否有执行在途（引擎无状态，但同一标签一次只跑一条，避免输出交错）。
    private(set) var isRunning = false

    /// 在途执行任务（关标签时取消——引擎的 await 会随 NIO future 完成自然结束）。
    private var runningTask: Task<Void, Never>?

    /// MySQL 续行缓冲：未以 `;` 结尾的行在此积累（与 mysql CLI 的 `->` 续行一致）。
    private(set) var pendingLines: [String] = []

    // MARK: - 会话（应用内终端复用连接：use / 临时变量等状态跨执行延续）

    private var mysqlConn: MySQLConnection?
    private var redisSess: RedisSession?
    /// 当前会话归属的连接配置（切换连接 → 旧会话作废）。
    private var sessionConnectionID: UUID?
    private var lastActivity = Date.distantPast
    /// 空闲多久后断开（下次执行时惰性重建）。
    private static let sessionIdleTimeout: TimeInterval = 5 * 60

    var selectedConnection: DBConnection? {
        connections.first { $0.id == selectedConnectionID }
    }

    init() {
        refreshConnections()
    }

    // MARK: - DevkitTool

    var dynamicTabTitle: String? {
        selectedConnection?.name
    }

    var hasUnsavedContent: Bool {
        !output.isEmpty
    }

    func makeView() -> AnyView {
        AnyView(DBToolView(tool: self))
    }

    /// 会话快照：只存选中连接与输入草稿（输出不持久化，重启后从空白开始）。
    private struct SessionState: Codable {
        var selectedConnectionID: UUID?
        var inputText: String
    }

    func sessionStateData() -> Data? {
        guard let state = try? JSONEncoder().encode(
            SessionState(selectedConnectionID: selectedConnectionID, inputText: inputText)
        ) else { return nil }
        return state
    }

    func restoreSessionState(_ data: Data) {
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
        refreshConnections()
        // 连接可能已被删除：只在仍存在时回填。
        if let id = state.selectedConnectionID, connections.contains(where: { $0.id == id }) {
            selectedConnectionID = id
        }
        inputText = state.inputText
    }

    /// 关标签：取消在途执行并断开会话连接。
    func teardownOnTabClose() {
        runningTask?.cancel()
        runningTask = nil
        let mysql = mysqlConn
        let redis = redisSess
        mysqlConn = nil
        redisSess = nil
        if let mysql {
            Task { await DBExec.closeMySQL(mysql) }
        }
        redis?.close()
    }

    // MARK: - 数据

    /// 重读连接列表（新建 / 编辑 / 删除后调用）。
    func refreshConnections() {
        connections = DBConnectionStore.all()
        if let id = selectedConnectionID, !connections.contains(where: { $0.id == id }) {
            selectedConnectionID = nil
        }
        if selectedConnectionID == nil {
            selectedConnectionID = connections.first?.id
        }
    }

    func clearOutput() {
        output.removeAll()
    }

    // MARK: - 执行

    /// 提示符行回车。MySQL：无 `;` 结尾 → 续行（提示符变 `->`），有 `;` → 执行整段；
    /// Redis：回车即执行（与 redis-cli 一致）。
    func submitLine() {
        guard !isRunning, let connection = selectedConnection else { return }
        let line = inputText
        inputText = ""
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        if connection.kind == .redis {
            run(commandText: line, echo: "redis> " + line, connection: connection)
            return
        }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasSuffix(";") {
            let prefix = pendingLines.isEmpty ? "mysql> " : "    -> "
            append(.input, prefix + line)
            pendingLines.append(line)
            return
        }
        if pendingLines.isEmpty {
            run(commandText: trimmed, echo: "mysql> " + line, connection: connection)
        } else {
            var echo = "mysql> " + pendingLines[0]
            for continued in pendingLines.dropFirst() {
                echo += "\n    -> " + continued
            }
            echo += "\n    -> " + line
            var full = pendingLines
            full.append(line)
            pendingLines.removeAll()
            run(commandText: full.joined(separator: "\n"), echo: echo, connection: connection)
        }
    }

    /// 执行一段 SQL / 命令（回显由调用方拼好传入）。
    private func run(commandText: String, echo: String, connection: DBConnection) {
        append(.input, echo)
        isRunning = true

        let kind = connection.kind
        let host = connection.host
        let port = connection.port
        let username = connection.normalizedUsername
        let password = connection.normalizedPassword
        let database = connection.normalizedDatabase
        let text = commandText

        runningTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.isRunning = false } }
            do {
                let result: DBExecResult
                switch kind {
                case .mysql:
                    // MySQL 用户名必有（编辑器默认 root）。
                    result = try await self?.mysqlExecute(host: host, port: port,
                                                          username: username ?? "root",
                                                          password: password, database: database,
                                                          sql: text) ?? Self.failResult()
                case .redis:
                    result = try await self?.redisExecute(host: host, port: port,
                                                          username: username, password: password,
                                                          database: database,
                                                          commandText: text) ?? Self.failResult()
                }
                if let errorText = result.errorText {
                    self?.append(.error, errorText)
                } else {
                    var output = result.text
                    if result.truncated { output += "\n…（输出过长已截断）" }
                    self?.append(.output, output)
                }
            } catch {
                self?.append(.error, error.localizedDescription)
            }
        }
    }

    private nonisolated static func failResult() -> DBExecResult {
        DBExecResult(ok: false, text: "", errorText: "内部状态错误", truncated: false)
    }

    // MARK: - 会话执行（复用连接；失效自动重建并重试一次）

    private func mysqlExecute(host: String, port: Int, username: String, password: String?,
                              database: String?, sql: String) async throws -> DBExecResult {
        var connection = try await mysqlSession(host: host, port: port, username: username,
                                                password: password, database: database)
        do {
            let result = try await DBExec.runMySQL(on: connection, sql: sql,
                                                   timeout: DBExec.defaultTimeout)
            lastActivity = .now
            return result
        } catch {
            // 查询超时已由引擎断开连接；其余连接类错误重建一次重试（SQL 错误不重试）。
            if isConnectionError(error), let fresh = try? await DBExec.openMySQL(host: host, port: port,
                                                                                 username: username,
                                                                                 password: password,
                                                                                 database: database,
                                                                                 timeout: DBExec.defaultTimeout) {
                mysqlConn = fresh
                lastActivity = .now
                return try await DBExec.runMySQL(on: fresh, sql: sql, timeout: DBExec.defaultTimeout)
            }
            if case DBExecError.queryTimeout = error {
                mysqlConn = nil
            }
            throw error
        }
    }

    private func mysqlSession(host: String, port: Int, username: String, password: String?,
                              database: String?) async throws -> MySQLConnection {
        if let mysqlConn, sessionConnectionID == selectedConnectionID,
           Date().timeIntervalSince(lastActivity) < Self.sessionIdleTimeout, !mysqlConn.isClosed {
            return mysqlConn
        }
        await dropMySQLSession()
        let fresh = try await DBExec.openMySQL(host: host, port: port, username: username,
                                               password: password, database: database,
                                               timeout: DBExec.defaultTimeout)
        mysqlConn = fresh
        sessionConnectionID = selectedConnectionID
        lastActivity = .now
        return fresh
    }

    private func dropMySQLSession() async {
        guard let mysql = mysqlConn else { return }
        mysqlConn = nil
        await DBExec.closeMySQL(mysql)
    }

    private func redisExecute(host: String, port: Int, username: String?, password: String?,
                              database: String?, commandText: String) async throws -> DBExecResult {
        var session = try await redisSession(host: host, port: port, username: username,
                                             password: password, database: database)
        do {
            let result = try await DBExec.runRedis(on: session, commandText: commandText,
                                                   timeout: DBExec.defaultTimeout)
            lastActivity = .now
            return result
        } catch {
            if isConnectionError(error), !session.isClosed {
                // 协议层异常但通道尚在：丢弃旧会话重建重试一次。
                session.close()
                redisSess = nil
                let fresh = try await redisSession(host: host, port: port, username: username,
                                                   password: password, database: database)
                lastActivity = .now
                return try await DBExec.runRedis(on: fresh, commandText: commandText,
                                                 timeout: DBExec.defaultTimeout)
            }
            if session.isClosed {
                redisSess = nil
            }
            throw error
        }
    }

    private func redisSession(host: String, port: Int, username: String?, password: String?,
                              database: String?) async throws -> RedisSession {
        if let redisSess, sessionConnectionID == selectedConnectionID,
           Date().timeIntervalSince(lastActivity) < Self.sessionIdleTimeout, !redisSess.isClosed {
            return redisSess
        }
        redisSess?.close()
        redisSess = nil
        let fresh = try await DBExec.openRedis(host: host, port: port, username: username,
                                               password: password, database: database,
                                               timeout: DBExec.defaultTimeout)
        redisSess = fresh
        sessionConnectionID = selectedConnectionID
        lastActivity = .now
        return fresh
    }

    /// 连接类错误（值得重建会话重试）；SQL 语法 / 权限等服务器错误不在此列。
    private func isConnectionError(_ error: Error) -> Bool {
        switch error {
        case DBExecError.queryTimeout, DBExecError.connectFailed, DBExecError.ioFailed:
            return true
        case DBExecError.redisProtocolError:
            return true // 连接断开在协议层表现为「连接已关闭」
        default:
            return false
        }
    }

    private func append(_ direction: DBOutputEntry.Direction, _ text: String) {
        output.append(DBOutputEntry(direction: direction, text: text))
        // 输出上限：控制内存与渲染量。
        if output.count > 500 {
            output.removeFirst(output.count - 500)
        }
    }
}
