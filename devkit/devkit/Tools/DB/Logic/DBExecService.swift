//
//  DBExecService.swift
//  devkit
//
//  数据库执行引擎：应用内「数据库」控制台与 AI 接入（MCP）共用。无状态单次执行——
//  每次调用连接 → 认证 → 执行 → 断开（与一次性 ssh_exec 同哲学，连接池留待后续）。
//
//  - Redis：手写 RESP2 协议（NIO TCP）。RESP 足够简单（5 种首字节类型），引客户端库不值当；
//    流程：connect → 有密码 AUTH（Redis 6+ ACL 用户名可选）→ 有 db 号 SELECT → 逐条执行。
//    命令行字符串按 redis-cli 习惯解析（尊重单双引号与反斜杠转义），回复渲染为 redis-cli 风格文本。
//  - MySQL：mysql-nio（Swift 直连，无需本机安装客户端；本工具固定关闭 TLS，适配内网常见场景）。
//    COM_QUERY 文本协议执行，结果渲染 TSV（表头 + 行，NULL → "NULL"）；多语句返回最后一条结果集。
//
//  超时统一在事件循环上 race（scheduleTask + promise + 迟到资源 close），而不是任务组 cancel：
//  mysql-nio 的 EventLoopFuture.get() 不响应 Task 取消，任务组方案会泄漏挂起的连接；
//  且 MySQLConnection.deinit 断言「关闭前不得析构」，超时路径必须显式 close 迟到资源。
//  输出上限 512KB（MySQL 另限 1000 行）。
//

import Foundation
import NIOCore
import NIOPosix
import MySQLNIO

// MARK: - 入口

nonisolated enum DBExec {
    /// 进程级共享事件循环组（单线程），模式同 SSHExec.group。
    static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    static let defaultTimeout: TimeInterval = 30
    static let minTimeout: TimeInterval = 5
    static let maxTimeout: TimeInterval = 600
    /// 单次输出上限。
    static let outputCap = 512 * 1024

    static func clampTimeout(_ value: Double?) -> TimeInterval {
        guard let value else { return defaultTimeout }
        return min(max(value, minTimeout), maxTimeout)
    }

    /// 执行 MySQL SQL（无状态：连 → 执行 → 断；MCP 接口用）。
    static func runMySQL(host: String, port: Int, username: String, password: String?,
                         database: String?, sql: String, timeout: TimeInterval) async throws -> DBExecResult {
        let connection = try await openMySQL(host: host, port: port,
                                             username: username, password: password,
                                             database: database, timeout: timeout)
        do {
            let result = try await runMySQL(on: connection, sql: sql, timeout: timeout)
            await closeMySQL(connection)
            return result
        } catch {
            await closeMySQL(connection)
            throw error
        }
    }

    /// 打开会话式连接（含瞬时不可达自动重试）。应用内终端持有复用。
    static func openMySQL(host: String, port: Int, username: String, password: String?,
                          database: String?, timeout: TimeInterval) async throws -> MySQLConnection {
        try await connectMySQLOnce(host: host, port: port, username: username,
                                   password: password, database: database, timeout: timeout)
    }

    /// 会话式执行：在既有连接上执行 SQL（应用内终端复用连接，`use` 等会话状态自然延续）。
    /// 查询超时会关闭连接（调用方下次重建）。
    static func runMySQL(on connection: MySQLConnection, sql: String,
                         timeout: TimeInterval) async throws -> DBExecResult {
        let loop = connection.eventLoop
        nonisolated(unsafe) var timedOut = false
        nonisolated(unsafe) var collectedRows: [MySQLRow] = []
        // 走 COM_QUERY 文本协议（simpleQuery）：USE / SET 等语句不被 prepared 协议支持
        // （服务器错误 1295），mysql CLI 与 Navicat 用的也是文本协议。
        let queryPromise = loop.makePromise(of: Void.self)
        let queryFuture = connection.simpleQuery(sql, onRow: { collectedRows.append($0) })
        let queryTimeoutTask = loop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) {
            timedOut = true
            queryPromise.fail(DBExecError.queryTimeout)
            // whenComplete 持有 connection 直到关闭完成，避免 deinit 断言（见主路径注释）。
            connection.close().whenComplete { _ in _ = connection }
        }
        queryFuture.whenComplete { result in
            queryTimeoutTask.cancel()
            guard !timedOut else { return } // 超时已 fail，迟到结果直接丢弃（连接已关）
            queryPromise.completeWith(result)
        }

        do {
            try await queryPromise.futureResult.get()
            // 必须等 close 完成：mysql-nio 的 deinit 断言「channel 已关闭」，
            // fire-and-forget 的 close 在对象立即释放时会触发 assert 崩溃。
            _ = try? await connection.close().get()
            return Self.renderMySQL(rows: collectedRows)
        } catch let error as DBExecError {
            _ = try? await connection.close().get()
            throw error
        } catch let error as MySQLError {
            _ = try? await connection.close().get()
            // 服务端 SQL 错误（语法 / 权限 / 约束等）→ 可读错误文本。
            throw DBExecError.connectFailed(Self.mysqlErrorText(error))
        } catch let error as IOError {
            _ = try? await connection.close().get()
            throw DBExecError.ioFailed("执行中断：" + Self.ioErrorText(error))
        } catch {
            _ = try? await connection.close().get()
            throw DBExecError.connectFailed(error.localizedDescription)
        }
    }

    /// 执行 Redis 命令（无状态：连 + AUTH/SELECT → 执行 → 断；MCP 接口用）。
    static func runRedis(host: String, port: Int, username: String?, password: String?,
                         database: String?, commandText: String, timeout: TimeInterval) async throws -> DBExecResult {
        let session = try await openRedis(host: host, port: port, username: username,
                                          password: password, database: database, timeout: timeout)
        defer { session.close() }
        return try await runRedis(on: session, commandText: commandText, timeout: timeout)
    }

    /// 打开会话式 Redis 连接（TCP + 认证 + 选库）。应用内终端持有复用。
    static func openRedis(host: String, port: Int, username: String?, password: String?,
                          database: String?, timeout: TimeInterval) async throws -> RedisSession {
        let session = try await RedisSession.connect(host: host, port: port)
        do {
            // 认证（有密码才发；Redis 6+ ACL 用户名与密码一起发）。
            if let password {
                let reply = try await session.command(
                    username != nil ? ["AUTH", username!, password] : ["AUTH", password],
                    timeout: timeout
                )
                if case .error(let message) = reply {
                    throw DBExecError.redisProtocolError("AUTH 失败：\(message)")
                }
            }
            // 选库。
            if let database {
                let reply = try await session.command(["SELECT", database], timeout: timeout)
                if case .error(let message) = reply {
                    throw DBExecError.redisProtocolError("SELECT 失败：\(message)")
                }
            }
            return session
        } catch {
            session.close()
            throw error
        }
    }

    /// 会话式执行：在既有连接上执行命令（应用内终端复用连接）。
    static func runRedis(on session: RedisSession, commandText: String,
                         timeout: TimeInterval) async throws -> DBExecResult {
        let lines = commandText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            throw DBExecError.redisProtocolError("没有可执行的命令")
        }
        let commands = lines.map { splitRedisCommand($0) }
        if commands.contains(where: { $0.isEmpty }) {
            throw DBExecError.redisProtocolError("存在无法解析的命令（检查引号是否闭合）")
        }

        var rendered: [String] = []
        do {
            for (line, parts) in zip(lines, commands) {
                let reply = try await session.command(parts, timeout: timeout)
                if case .error(let message) = reply {
                    rendered.append("> \(line)\n(error) \(message)")
                } else {
                    rendered.append("> \(line)\n\(renderRESP(reply))")
                }
            }
        } catch let error as DBExecError {
            throw error
        } catch {
            throw DBExecError.redisProtocolError(error.localizedDescription)
        }

        var text = rendered.joined(separator: "\n")
        var truncated = false
        if text.utf8.count > outputCap {
            text = String(text.prefix(outputCap))
            truncated = true
        }
        return DBExecResult(ok: true, text: text, errorText: nil, truncated: truncated)
    }

    /// 关闭会式连接（等待关闭完成，避免 mysql-nio deinit 断言）。
    static func closeMySQL(_ connection: MySQLConnection) async {
        _ = try? await connection.close().get()
    }

    private static func connectMySQLOnce(host: String, port: Int, username: String, password: String?,
                                         database: String?, timeout: TimeInterval) async throws -> MySQLConnection {
        // 瞬时不可达自动重试：内网 / VPN 目标首次 connect 常因路由或隧道未就绪被内核立即拒绝
        // （ENETUNREACH / EHOSTUNREACH），一两秒后即恢复——自动重试一次。
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await connectMySQLOnceInner(host: host, port: port, username: username,
                                                       password: password, database: database, timeout: timeout)
            } catch let error as IOError where attempt == 1 && isTransientUnreachable(error) {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private static func connectMySQLOnceInner(host: String, port: Int, username: String, password: String?,
                                              database: String?, timeout: TimeInterval) async throws -> MySQLConnection {
        nonisolated(unsafe) var timedOut = false
        let loop = group.next()

        let connectFuture = MySQLConnection.connect(
            to: try SocketAddress.makeAddressResolvingHost(host, port: port),
            username: username,
            database: database ?? "",
            password: password,
            tlsConfiguration: nil,
            on: loop
        )
        // 连接超时：到点 fail promise 并关掉迟到的连接（同 NIOSSHExecTransport 的模式）。
        let connectPromise = loop.makePromise(of: MySQLConnection.self)
        let connectTimeoutTask = loop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) {
            timedOut = true
            connectPromise.fail(DBExecError.connectFailed("连接超时"))
            connectFuture.whenComplete { result in
                if case .success(let late) = result {
                    late.close().whenComplete { _ in _ = late }
                }
            }
        }
        connectFuture.whenComplete { result in
            connectTimeoutTask.cancel()
            guard !timedOut else {
                if case .success(let late) = result {
                    late.close().whenComplete { _ in _ = late }
                }
                return
            }
            connectPromise.completeWith(result)
        }

        do {
            return try await connectPromise.futureResult.get()
        } catch let error as MySQLError {
            throw DBExecError.connectFailed(mysqlErrorText(error))
        } catch let error as IOError {
            throw DBExecError.ioFailed(ioErrorText(error))
        } catch let error as DBExecError {
            throw error
        } catch {
            throw DBExecError.connectFailed(error.localizedDescription)
        }
    }

    /// 瞬时不可达类错误（值得重试）；ECONNREFUSED（端口未开）不在此列——重试无意义。
    fileprivate static func isTransientUnreachable(_ error: IOError) -> Bool {
        switch error.errnoCode {
        case EHOSTUNREACH, ENETUNREACH, ETIMEDOUT:
            return true
        default:
            return false
        }
    }

    // MARK: - MySQL 渲染与错误翻译

    /// 行集 → mysql CLI 风格的 ASCII 表格（+---+ 边框、右缘竖线、`N rows in set` 尾注）；
    /// 无结果集时输出 `Query OK`（文本协议不回传 affected rows）。
    private static func renderMySQL(rows: [MySQLRow]) -> DBExecResult {
        let capRows = 1000
        var truncated = false
        var limited = rows
        if rows.count > capRows {
            limited = Array(rows.prefix(capRows))
            truncated = true
        }

        // 单元格文本（NULL 显示为 NULL）。
        func cellText(_ row: MySQLRow, _ index: Int) -> String {
            guard index < row.columnDefinitions.count else { return "NULL" }
            let column = row.columnDefinitions[index]
            let data = MySQLData(type: column.columnType,
                                 format: row.format,
                                 buffer: index < row.values.count ? row.values[index] : nil,
                                 isUnsigned: column.flags.contains(.COLUMN_UNSIGNED))
            guard data.buffer != nil else { return "NULL" }
            return data.string ?? "NULL"
        }

        guard let first = limited.first else {
            return DBExecResult(ok: true, text: "Query OK", errorText: nil, truncated: truncated)
        }

        let columns = first.columnDefinitions.map(\.name)
        let tableRows = limited.map { row in (0..<columns.count).map { cellText(row, $0) } }
        // 列宽 = max(列名, 各单元格) 的字符数（与 mysql CLI 一致按字符数，CJK 会略窄）。
        var widths = columns.map(\.count)
        for row in tableRows {
            for (index, value) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], value.count)
            }
        }
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        let separator = "+" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "+"
        func line(_ values: [String]) -> String {
            "|" + zip(values, widths).map { " \(pad($0, $1)) " }.joined(separator: "|") + "|"
        }

        var lines = [separator, line(columns), separator]
        for row in tableRows {
            lines.append(line(row))
        }
        lines.append(separator)
        lines.append("\(rows.count) row\(rows.count == 1 ? "" : "s") in set")

        var text = lines.joined(separator: "\n")
        if text.utf8.count > outputCap {
            text = String(decoding: Data(text.utf8.prefix(outputCap)), as: UTF8.self)
            truncated = true
        }
        return DBExecResult(ok: true, text: text, errorText: nil, truncated: truncated)
    }

    /// 底层 IO 错误 → 可读原因（NIO 的 localizedDescription 只有 "IOError error 1" 这类晦涩码）。
    private static func ioErrorText(_ error: IOError) -> String {
        switch error.errnoCode {
        case ECONNREFUSED:
            return "连接被拒绝（目标端口未开放）"
        case ETIMEDOUT:
            return "连接超时"
        case EHOSTUNREACH, ENETUNREACH:
            return "网络不可达"
        default:
            return error.localizedDescription
        }
    }

    /// MySQLError → 可读文本（不携带 host）。
    private static func mysqlErrorText(_ error: MySQLError) -> String {
        switch error {
        case .server(let packet):
            return "服务器错误 \(packet.errorCode.rawValue)：\(packet.errorMessage)"
        case .closed:
            return "连接已关闭"
        case .invalidSyntax(let m):
            return "SQL 语法错误：\(m)"
        case .duplicateEntry(let m):
            return "唯一键冲突：\(m)"
        case .unsupportedAuthPlugin(let name):
            return "不支持的认证插件 \(name)（可尝试改用 mysql_native_password）"
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Redis 命令行解析与渲染

    /// 命令行 → 参数数组：按空白切分，尊重单引号 / 双引号与反斜杠转义（redis-cli 习惯）。
    static func splitRedisCommand(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var hasToken = false
        var iterator = line.makeIterator()

        func push() {
            if hasToken || !current.isEmpty {
                parts.append(current)
                current = ""
                hasToken = false
            }
        }

        while let ch = iterator.next() {
            if ch == "'" && !inDouble {
                inSingle.toggle()
                hasToken = true
            } else if ch == "\"" && !inSingle {
                inDouble.toggle()
                hasToken = true
            } else if ch == "\\" && (inDouble || (!inSingle && !inDouble)), let next = iterator.next() {
                // 双引号内与裸文本中的反斜杠转义下一字符；单引号内原样保留。
                current.append(next)
                hasToken = true
            } else if (ch == " " || ch == "\t") && !inSingle && !inDouble {
                push()
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if inSingle || inDouble {
            return [] // 引号未闭合 → 非法
        }
        push()
        return parts
    }

    /// redis-cli 风格渲染。
    static func renderRESP(_ value: RESPValue) -> String {
        renderRESPLevel(value, indent: "")
    }

    private static func renderRESPLevel(_ value: RESPValue, indent: String) -> String {
        switch value {
        case .simpleString(let s):
            return s
        case .error(let message):
            return "(error) \(message)"
        case .integer(let n):
            return "(integer) \(n)"
        case .bulk(nil):
            return "(nil)"
        case .bulk(let s?):
            return "\"\(escapeRedis(s))\""
        case .array(nil):
            return "(nil)"
        case .array(let items?):
            guard !items.isEmpty else { return "(empty array)" }
            return items.enumerated().map { index, item in
                let child = renderRESPLevel(item, indent: indent + "  ")
                if case .array = item {
                    return "\(indent)\(index + 1))\n\(child)"
                }
                return "\(indent)\(index + 1)) \(child)"
            }.joined(separator: "\n")
        }
    }

    private static func escapeRedis(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - RESP2 值

/// RESP2 值（够用的子集：简单串 / 错误 / 整数 / 批量串 / 数组）。
nonisolated enum RESPValue: Sendable {
    case simpleString(String)
    case error(String)
    case integer(Int64)
    case bulk(String?)
    case array([RESPValue]?)
}

// MARK: - Redis 会话（单条 TCP 连接上的串行请求-应答）

/// 一次 Redis 执行的连接封装：命令串行发送（发一条、等回复、再发下一条）。
nonisolated final class RedisSession: @unchecked Sendable {
    private let channel: Channel
    private let replyBox: ReplyBox

    private init(channel: Channel, replyBox: ReplyBox) {
        self.channel = channel
        self.replyBox = replyBox
    }

    /// 建连（瞬时不可达自动重试一次，与 MySQL 引擎同理）。
    static func connect(host: String, port: Int) async throws -> RedisSession {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await connectOnce(host: host, port: port)
            } catch let error as IOError where attempt == 1 && DBExec.isTransientUnreachable(error) {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private static func connectOnce(host: String, port: Int) async throws -> RedisSession {
        let replyBox = ReplyBox()
        let bootstrap = ClientBootstrap(group: DBExec.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        RESPHandler(replyBox: replyBox)
                    )
                }
            }
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        // 连接超时：镜像 NIOSSHExecTransport 的 promise + scheduleTask 模式。
        let connectFuture = bootstrap.connect(host: host, port: port)
        let promise = connectFuture.eventLoop.makePromise(of: Channel.self)
        // 超时标志：scheduleTask 回调与 whenComplete 回调同环串行，普通变量即可。
        nonisolated(unsafe) var timedOut = false
        let timeoutTask = connectFuture.eventLoop.scheduleTask(in: .seconds(15)) {
            timedOut = true
            promise.fail(DBExecError.connectFailed("连接超时"))
            connectFuture.whenComplete { result in
                if case .success(let late) = result { _ = late.close() }
            }
        }
        connectFuture.whenComplete { result in
            timeoutTask.cancel()
            guard !timedOut else {
                if case .success(let late) = result { _ = late.close() }
                return
            }
            promise.completeWith(result)
        }
        let channel = try await promise.futureResult.get()
        return RedisSession(channel: channel, replyBox: replyBox)
    }

    /// 发送一条命令并等待完整回复；整体带超时（超时即断开连接，等待者随连接关闭被唤醒）。
    func command(_ parts: [String], timeout: TimeInterval) async throws -> RESPValue {
        try await withThrowingTaskGroup(of: RESPValue.self) { group in
            group.addTask {
                try await self.sendAndAwait(parts)
            }
            group.addTask { [channel] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // 断开连接 → RESPHandler 收到 channelInactive → 唤醒等待者，避免 continuation 泄漏。
                channel.close(mode: .all, promise: nil)
                throw DBExecError.queryTimeout
            }
            guard let value = try await group.next() else {
                throw DBExecError.queryTimeout
            }
            group.cancelAll()
            return value
        }
    }

    private func sendAndAwait(_ parts: [String]) async throws -> RESPValue {
        replyBox.reset()
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("*\(parts.count)\r\n")
        for part in parts {
            buffer.writeString("$\(part.utf8.count)\r\n")
            buffer.writeString(part)
            buffer.writeString("\r\n")
        }
        channel.writeAndFlush(buffer, promise: nil)
        return try await replyBox.awaitReply()
    }

    /// 连接是否已断（供复用方在执行前检查，失效则重建）。
    var isClosed: Bool { !channel.isActive }

    func close() {
        channel.close(mode: .all, promise: nil)
    }
}

/// 待回复槽：驱动协程挂起等待，事件循环解析出完整回复后唤醒。一次一个等待者（命令串行）。
/// 注意缓存竞态：回环网络下回复可能在 `awaitReply` 注册等待者**之前**到达（writeAndFlush
/// 是异步的），fulfill 时 waiter 尚为 nil —— 先到的结果必须缓存，否则协程永久挂起。
nonisolated final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var waiter: CheckedContinuation<RESPValue, Error>?
    nonisolated(unsafe) private var pending: Result<RESPValue, Error>?

    func awaitReply() async throws -> RESPValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RESPValue, Error>) in
            lock.lock()
            if let ready = pending {
                // 回复先于等待者到达：立即返回缓存。
                pending = nil
                lock.unlock()
                continuation.resume(with: ready)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    /// 每轮命令执行前调用：丢弃上一轮遗留的陈旧缓存（断连通知等）。
    func reset() {
        lock.lock()
        pending = nil
        lock.unlock()
    }

    /// 事件循环侧：回复就绪（或失败）。与 `awaitReply` 一对一，先到则缓存。
    func fulfill(_ result: Result<RESPValue, Error>) {
        lock.lock()
        if let waiter = self.waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(with: result)
            return
        }
        pending = result
        lock.unlock()
    }
}

/// RESP2 解析器 + 通道处理器：累积入站字节，解析出一条完整回复即唤醒等待者。
nonisolated final class RESPHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// 单回复上限：防失控命令（如大 KEYS）拖垮内存。
    private static let maxReplyBytes = 2 * 1024 * 1024

    private let replyBox: ReplyBox
    /// 累积的入站字节（仅在事件循环上触碰）。
    private var accumulated: [UInt8] = []
    init(replyBox: ReplyBox) {
        self.replyBox = replyBox
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            accumulated.append(contentsOf: bytes)
        }
        if accumulated.count > Self.maxReplyBytes {
            replyBox.fulfill(.failure(DBExecError.redisProtocolError("回复超过 2MB")))
            context.close(promise: nil)
            return
        }
        switch Self.parse(accumulated, at: 0) {
        case .value(let value, let consumed):
            // 消费掉已解析字节；本轮交付后由上层发下一条命令（串行协议）。
            accumulated.removeFirst(consumed)
            replyBox.fulfill(.success(value))
        case .needMore:
            break // 等待更多数据
        case .invalid(let message):
            replyBox.fulfill(.failure(DBExecError.redisProtocolError(message)))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        replyBox.fulfill(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // 仅在本轮还没有交付过回复时才有意义；陈旧通知会落进 pending，被下一轮 reset 丢弃。
        replyBox.fulfill(.failure(DBExecError.redisProtocolError("连接已关闭")))
        context.fireChannelInactive()
    }

    // MARK: - RESP2 解析（统一按「绝对偏移」工作，不做数组拷贝）

    private enum ParseOutcome {
        case value(RESPValue, consumed: Int)
        case needMore
        case invalid(String)
    }

    /// 从 `start` 偏移解析一个 RESP 值；成功返回值与已消费字节数。
    private static func parse(_ bytes: [UInt8], at start: Int) -> ParseOutcome {
        guard start < bytes.count else { return .needMore }
        switch bytes[start] {
        case UInt8(ascii: "+"):
            return parseSimple(bytes, at: start, make: { .simpleString($0) })
        case UInt8(ascii: "-"):
            return parseSimple(bytes, at: start, make: { .error($0) })
        case UInt8(ascii: ":"):
            return parseSimple(bytes, at: start, make: { text in
                guard let n = Int64(text) else { return nil }
                return .integer(n)
            })
        case UInt8(ascii: "$"):
            return parseBulk(bytes, at: start)
        case UInt8(ascii: "*"):
            return parseArray(bytes, at: start)
        default:
            return .invalid("未知回复类型字节")
        }
    }

    /// 解析「首字节 + 文本 + CRLF」。
    private static func parseSimple(_ bytes: [UInt8], at start: Int,
                                    make: (String) -> RESPValue?) -> ParseOutcome {
        var index = start + 1
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "\r"), bytes[index + 1] == UInt8(ascii: "\n") {
                let text = String(decoding: bytes[(start + 1)..<index], as: UTF8.self)
                guard let value = make(text) else { return .invalid("行格式错误") }
                return .value(value, consumed: index + 2 - start)
            }
            index += 1
        }
        return .needMore
    }

    private static func parseBulk(_ bytes: [UInt8], at start: Int) -> ParseOutcome {
        guard let (length, headerConsumed) = readIntLine(bytes, at: start) else { return .needMore }
        if length == -1 {
            return .value(.bulk(nil), consumed: headerConsumed)
        }
        guard length >= 0, length <= Self.maxReplyBytes else { return .invalid("非法长度") }
        let payloadStart = start + headerConsumed
        let payloadEnd = payloadStart + Int(length)
        guard payloadEnd + 2 <= bytes.count else { return .needMore }
        guard bytes[payloadEnd] == UInt8(ascii: "\r"), bytes[payloadEnd + 1] == UInt8(ascii: "\n") else {
            return .invalid("bulk 结尾缺少 CRLF")
        }
        let payload = String(decoding: bytes[payloadStart..<payloadEnd], as: UTF8.self)
        return .value(.bulk(payload), consumed: headerConsumed + Int(length) + 2)
    }

    private static func parseArray(_ bytes: [UInt8], at start: Int) -> ParseOutcome {
        guard let (count, headerConsumed) = readIntLine(bytes, at: start) else { return .needMore }
        if count == -1 {
            return .value(.array(nil), consumed: headerConsumed)
        }
        guard count >= 0, count <= 1_000_000 else { return .invalid("非法数组长度") }
        var offset = start + headerConsumed
        var items: [RESPValue] = []
        for _ in 0..<count {
            switch parse(bytes, at: offset) {
            case .value(let value, let consumed):
                items.append(value)
                offset += consumed
            case .needMore:
                return .needMore
            case .invalid(let m):
                return .invalid(m)
            }
        }
        return .value(.array(items), consumed: offset - start)
    }

    /// 读取「首字节 + 整数文本 + CRLF」；返回 (整数值, 已消费字节数)。
    private static func readIntLine(_ bytes: [UInt8], at start: Int) -> (Int, Int)? {
        var index = start + 1
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "\r"), bytes[index + 1] == UInt8(ascii: "\n") {
                let text = String(decoding: bytes[(start + 1)..<index], as: UTF8.self)
                guard let n = Int(text) else { return nil }
                return (n, index + 2 - start)
            }
            index += 1
        }
        return nil
    }
}
