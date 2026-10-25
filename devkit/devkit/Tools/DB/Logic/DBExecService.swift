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

    /// 执行 MySQL SQL（可多语句，返回最后一条结果集的 TSV 渲染）。
    static func runMySQL(host: String, port: Int, username: String, password: String?,
                         database: String?, sql: String, timeout: TimeInterval) async throws -> DBExecResult {
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
                if case .success(let late) = result { _ = late.close() }
            }
        }
        connectFuture.whenComplete { result in
            connectTimeoutTask.cancel()
            guard !timedOut else {
                if case .success(let late) = result { _ = late.close() }
                return
            }
            connectPromise.completeWith(result)
        }

        let connection: MySQLConnection
        do {
            connection = try await connectPromise.futureResult.get()
        } catch let error as MySQLError {
            throw DBExecError.connectFailed(Self.mysqlErrorText(error))
        } catch let error as IOError {
            throw DBExecError.ioFailed(Self.ioErrorText(error))
        } catch {
            throw DBExecError.connectFailed(error.localizedDescription)
        }

        // 查询超时：到点 fail promise 并断开连接（查询随之失败）。
        let queryPromise = loop.makePromise(of: [MySQLRow].self)
        let queryFuture = connection.query(sql)
        let queryTimeoutTask = loop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) {
            timedOut = true
            queryPromise.fail(DBExecError.queryTimeout)
            _ = connection.close()
        }
        queryFuture.whenComplete { result in
            queryTimeoutTask.cancel()
            guard !timedOut else { return } // 超时已 fail，迟到结果直接丢弃（连接已关）
            queryPromise.completeWith(result)
        }

        do {
            let rows = try await queryPromise.futureResult.get()
            _ = connection.close()
            return Self.renderMySQL(rows: rows)
        } catch let error as DBExecError {
            _ = connection.close()
            throw error
        } catch let error as MySQLError {
            _ = connection.close()
            // 服务端 SQL 错误（语法 / 权限 / 约束等）→ 可读错误文本。
            throw DBExecError.connectFailed(Self.mysqlErrorText(error))
        } catch let error as IOError {
            _ = connection.close()
            throw DBExecError.ioFailed("执行中断：" + Self.ioErrorText(error))
        } catch {
            _ = connection.close()
            throw DBExecError.connectFailed(error.localizedDescription)
        }
    }

    /// 执行 Redis 命令（commandText 每非空行一条，命令行式语法）。
    static func runRedis(host: String, port: Int, username: String?, password: String?,
                         database: String?, commandText: String, timeout: TimeInterval) async throws -> DBExecResult {
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

        let session = try await RedisSession.connect(host: host, port: port)
        defer { session.close() }

        var rendered: [String] = []
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

    // MARK: - MySQL 渲染与错误翻译

    /// 行集 → TSV 文本；空结果返回 "OK（无结果集）"。
    private static func renderMySQL(rows: [MySQLRow]) -> DBExecResult {
        let capRows = 1000
        var truncated = false
        var limited = rows
        if rows.count > capRows {
            limited = Array(rows.prefix(capRows))
            truncated = true
        }

        guard let first = limited.first else {
            return DBExecResult(ok: true, text: "OK（无结果集）", errorText: nil, truncated: truncated)
        }

        let columns = first.columnDefinitions.map(\.name)
        var lines = [columns.joined(separator: "\t")]
        for row in limited {
            lines.append((0..<columns.count).map { index in
                let column = row.columnDefinitions[index]
                let data = MySQLData(type: column.columnType,
                                     format: row.format,
                                     buffer: index < row.values.count ? row.values[index] : nil,
                                     isUnsigned: column.flags.contains(.COLUMN_UNSIGNED))
                return data.buffer == nil ? "NULL" : (data.string ?? "NULL")
            }.joined(separator: "\t"))
        }
        var text = lines.joined(separator: "\n") + "\n(\(rows.count) 行)"
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

    static func connect(host: String, port: Int) async throws -> RedisSession {
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
