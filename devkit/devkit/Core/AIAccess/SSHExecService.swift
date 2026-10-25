//
//  SSHExecService.swift
//  devkit
//
//  AI 接入的远程命令执行核心：一次性执行与持久会话共用同一套「无 pty shell + 标记协议」。
//
//  双引擎（与 SSH 终端工具一致，按记录的认证方式选择）：
//  - 密码认证：进程内 NIOSSH，session 子通道 + ShellRequest（不申请 pty —— 远端 shell 进入
//    非交互模式：无命令回显、无提示符，stdout/stderr 分离干净）。主机需先在 SSH 终端工具里
//    完成过一次 TOFU 信任（与 SFTP 工具的约束一致）。
//  - 私钥认证：常驻 /usr/bin/ssh 子进程（BatchMode，认证失败即退出而非挂起；首连
//    accept-new 写入应用私有 known_hosts，不污染用户 ~/.ssh，参数与 SFTP 的 SystemSSHTransport 对齐）。
//
//  执行协议：每条命令下发两行 —— 命令本身 + `echo __DK<随机标记>__$?`。逐轮扫描 stdout 中的
//  标记行取得退出码，标记行之前的内容即命令输出。shell 意外退出（未见标记）按「通道已关闭」
//  返回并附上已收到的 stderr；超时则直接关闭会话并返回部分输出 —— shell 里可能还挂着前台
//  进程，无法安全续用。`$?` 语法要求远端登录 shell 为 POSIX 系（sh/bash/zsh/ksh/dash 等），
//  fish/csh 作为登录 shell 的主机暂不支持会话执行。
//
//  远端输出经 BytePump（带锁字节累积）+ 20ms 轮询增量拉取 —— 不用 AsyncStream：消费任务被
//  cancel 会把流永久终止（见 SSHClient.incoming 的教训），泵式拉取天然支持同一连接上多次执行。
//
//  会话由 SSHSessionRegistry（主 actor）管理：空闲 30 分钟 / 最长存活 2 小时回收，全局上限
//  8 个；一次性执行 = 内部临时会话，用完即关。
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - 结果与错误

/// 一次远程命令执行的结果（已按上限截断）。
struct SSHExecResult: Sendable {
    /// 命令退出码；nil = 未知（超时 / shell 已退出）。
    var exitCode: Int32?
    var stdoutText: String
    var stderrText: String
    /// 输出超过上限被截断。
    var truncated: Bool
    /// 执行超时（会话已被关闭）。
    var timedOut: Bool
    /// shell 在命令完成前退出（远端登出 / 连接断开 / ssh 报错，原因见 stderr）。
    var shellExited: Bool
}

enum SSHExecError: LocalizedError {
    /// 密码引擎：主机尚未在 SSH 终端工具里信任过。
    case hostNotTrusted
    /// 连接阶段失败 / 超时。
    case connectFailed(String)
    case connectTimeout
    /// 私钥文件缺失。
    case keyMissing
    /// 打开会话时默认目录不存在。
    case badWorkingDirectory(String)
    /// 会话不存在或已回收。
    case sessionNotFound
    /// 会话已在超时 / 上限回收后被关闭。
    case sessionClosed
    /// 并发会话数达到上限。
    case sessionLimitReached

    var errorDescription: String? {
        switch self {
        case .hostNotTrusted:
            return "该主机尚未在 devkit 中信任：请先在「SSH 终端」工具里连接一次这条记录，确认主机可信后再使用 AI 接入"
        case .connectFailed(let m): return "连接失败：\(m)"
        case .connectTimeout: return "连接超时"
        case .keyMissing: return "找不到私钥文件，请在 devkit 中重新选择"
        case .badWorkingDirectory(let m): return "默认目录不可用：\(m)"
        case .sessionNotFound: return "会话不存在（可能已被回收），请重新 ssh_open_session"
        case .sessionClosed: return "会话已关闭（超时或达到存活上限），请重新 ssh_open_session"
        case .sessionLimitReached: return "并发会话数已达上限（8），请先 ssh_close_session 释放"
        }
    }
}

// MARK: - 共享事件循环

nonisolated enum SSHExec {
    /// 底层 IO 错误 → 可读原因（不携带 host）。
    static func ioErrorText(_ error: IOError) -> String {
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

    /// 进程级共享事件循环组（单线程）。密码引擎的全部连接复用它；随进程退出释放，
    /// 生命周期与 DatabaseManager 等单例一致（NIOSSH 通道在会话关闭时逐一 close，
    /// 不做 group 级 shutdown，避免拆掉使用中的连接）。
    static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}

// MARK: - 输出泵

/// 线程安全的字节累积泵：NIO 事件循环 / 子进程管道线程 append，执行循环增量拉取（drain 全量）。
/// 单活跃消费者（会话内执行天然串行），不做多消费者唤醒。
nonisolated final class BytePump: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    /// 取走当前累积的全部字节并清空。
    func consume() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let new = buffer
        buffer.removeAll(keepingCapacity: true)
        return new
    }
}

/// shell 退出码的线程安全暂存：NIOSSH 的 ExitStatus 事件 / 子进程 termination 回调写入。
/// 标记协议取不到退出码时兜底（典型：命令以 `exit N` 结束直接终止 shell，标记行不会执行）。
nonisolated final class ExitStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var value: Int32?

    func set(_ code: Int32) {
        lock.lock()
        value = code
        lock.unlock()
    }

    func get() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - 传输抽象

/// 一条 SSH 连接上的双向字节管道（两个引擎各一份实现）。
nonisolated protocol SSHExecTransport: AnyObject, Sendable {
    var stdout: BytePump { get }
    var stderr: BytePump { get }
    /// 连接 / 进程终止信号（单向闩锁，复用 SSHClient 的实现）。
    var closed: AsyncSignal { get }
    /// shell 退出码暂存（标记协议的兜底来源）。
    var exitStatus: ExitStatusBox { get }
    /// 建连（或启动子进程）。失败抛出（消息可能含 host，由外层统一脱敏）。
    func launch() async throws
    /// 把文本写入远端 shell 的 stdin。
    func write(_ text: String)
    /// 关闭（幂等；正在进行的 launch 也会被拆掉）。
    func shutdown()
}

// MARK: - NIOSSH 引擎（密码认证）

nonisolated final class NIOSSHExecTransport: SSHExecTransport, @unchecked Sendable {
    let stdout = BytePump()
    let stderr = BytePump()
    let closed = AsyncSignal()
    let exitStatus = ExitStatusBox()

    private let host: String
    private let port: Int
    private let auth: NIOSSHClientUserAuthenticationDelegate
    private let lock = NSLock()
    private var connection: Channel?
    private var shell: Channel?
    /// 连接超时标志：仅在事件循环线程上读写（connect 回调与 scheduleTask 同环串行）。
    nonisolated(unsafe) private var connectTimedOut = false

    init(host: String, port: Int, auth: NIOSSHClientUserAuthenticationDelegate) {
        self.host = host
        self.port = port
        self.auth = auth
    }

    func launch() async throws {
        let bootstrap = ClientBootstrap(group: SSHExec.group)
            .channelInitializer { [auth] channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(
                            .init(userAuthDelegate: auth,
                                  serverAuthDelegate: AIExecAcceptAllHostKeysDelegate())
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                }
            }
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        // 连接超时：到点仍未完成则让 promise 失败；若此后 TCP 才连上，把迟到通道关掉防泄漏。
        let connectFuture = bootstrap.connect(host: host, port: port)
        let promise = connectFuture.eventLoop.makePromise(of: Channel.self)
        let timeoutTask = connectFuture.eventLoop.scheduleTask(in: .seconds(20)) { [weak self] in
            self?.connectTimedOut = true
            promise.fail(SSHExecError.connectTimeout)
            connectFuture.whenComplete { result in
                if case .success(let late) = result { late.close(promise: nil) }
            }
        }
        connectFuture.whenComplete { [weak self] result in
            timeoutTask.cancel()
            guard let self, !self.connectTimedOut else {
                if case .success(let ch) = result { ch.close(promise: nil) }
                return
            }
            switch result {
            case .success(let channel): promise.succeed(channel)
            case .failure(let error): promise.fail(error)
            }
        }
        let conn: Channel
        do {
            conn = try await promise.futureResult.get()
        } catch let error as SSHExecError {
            throw error
        } catch let error as NIOConnectionError {
            // NIO 的 localizedDescription 只有 "NIOConnectionError error 1" 这类晦涩文本，
            // 且其 description 含目标 host —— 翻译成固定文案，避免敏感信息外流。
            if error.dnsAError != nil || error.dnsAAAAError != nil {
                throw SSHExecError.connectFailed("域名解析失败")
            }
            let refused = error.connectionErrors.contains { failure in
                (failure.error as? IOError)?.errnoCode == ECONNREFUSED
            }
            throw SSHExecError.connectFailed(refused
                                             ? "连接被拒绝（目标端口未开放）"
                                             : "无法建立 TCP 连接（网络不可达或超时）")
        } catch let error as IOError {
            throw SSHExecError.connectFailed(SSHExec.ioErrorText(error))
        } catch is SSHExecError {
            throw SSHExecError.connectTimeout
        } catch let error as NIOSSHError {
            // 服务器拒绝认证后通常直接断 TCP（报 tcpShutdown），必须与网络故障区分，
            // 否则模型会把凭据问题误判为网络波动而盲目重试。
            let text = String(describing: error).lowercased()
            if text.contains("auth") {
                throw SSHExecError.connectFailed("认证失败：请检查 devkit 中该记录保存的用户名 / 密码 / 私钥")
            }
            throw SSHExecError.connectFailed("连接被远端关闭（常见原因：认证失败、服务器限制连接或网络中断）；若确认凭据无误可重试")
        } catch {
            // ChannelError 等底层类型 localizedDescription 晦涩（如 "ChannelError error 0"），统一为可读文案。
            throw SSHExecError.connectFailed("无法建立连接（网络不可达、端口未开放或连接超时）")
        }

        lock.lock()
        connection = conn
        lock.unlock()

        // 在已建立的连接上创建 session 子通道并启动 shell（不申请 pty）。
        // 必须在连接事件循环的 future 回调里调 createChannel（线程安全要求，见 SSHClient.openShell 注释）。
        let shellChannel = try await conn.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let shellPromise = conn.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(shellPromise, channelType: .session) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(
                        SSHExecShellHandler(stdout: self.stdout, stderr: self.stderr,
                                            closed: self.closed, exitStatus: self.exitStatus)
                    )
                }
            }
            return shellPromise.futureResult
        }.get()

        lock.lock()
        shell = shellChannel
        lock.unlock()
    }

    func write(_ text: String) {
        lock.lock()
        let target = shell
        lock.unlock()
        guard let target else { return }
        var buffer = target.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        target.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }

    func shutdown() {
        lock.lock()
        let conn = connection
        let sh = shell
        connection = nil
        shell = nil
        lock.unlock()
        sh?.close(mode: .all, promise: nil)
        conn?.close(mode: .all, promise: nil)
        closed.fire()
    }
}

/// session 子通道处理器：进入 shell（无 pty），把 stdout/stderr 字节分流进两个泵。
nonisolated final class SSHExecShellHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = Never

    private let stdout: BytePump
    private let stderr: BytePump
    private let closed: AsyncSignal
    private let exitStatus: ExitStatusBox

    init(stdout: BytePump, stderr: BytePump, closed: AsyncSignal, exitStatus: ExitStatusBox) {
        self.stdout = stdout
        self.stderr = stderr
        self.closed = closed
        self.exitStatus = exitStatus
    }

    nonisolated func channelActive(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: false), promise: nil)
        context.fireChannelActive()
    }

    nonisolated func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // 命令以 exit 结束时 shell 直接退出、标记行不会执行 —— 记下远端报告的退出码兜底。
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus.set(Int32(exit.exitStatus))
        }
        context.fireUserInboundEventTriggered(event)
    }

    nonisolated func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data else {
            context.fireChannelRead(data)
            return
        }
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        if channelData.type == .stdErr {
            stderr.append(Data(bytes))
        } else if channelData.type == .channel {
            stdout.append(Data(bytes))
        }
    }

    nonisolated func channelInactive(context: ChannelHandlerContext) {
        closed.fire()
        context.fireChannelInactive()
    }
}

/// 主机信任在连接前已按 host:port 维度校验（沿用 SSH 终端工具的 TOFU 记录），故此处直接放行。
nonisolated final class AIExecAcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    nonisolated func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

// MARK: - 系统 ssh 引擎（私钥认证）

nonisolated final class SystemSSHExecTransport: SSHExecTransport, @unchecked Sendable {
    let stdout = BytePump()
    let stderr = BytePump()
    let closed = AsyncSignal()
    let exitStatus = ExitStatusBox()

    private let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stderrTail = Data()

    init(keyURL: URL, knownHostsPath: String, host: String, port: Int, username: String) {
        self.arguments = [
            "-o", "BatchMode=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-o", "ConnectTimeout=15",
            "-i", keyURL.path,
            "-p", String(port),
            "\(username)@\(host)",
            // 不带命令：远端起登录 shell，由本层往 stdin 喂命令（stdin 是管道 → 非交互模式）。
        ]
    }

    func launch() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let out = stdoutPipe.fileHandleForReading
        let err = stderrPipe.fileHandleForReading
        out.readabilityHandler = { [stdout] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { stdout.append(data) }
        }
        err.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.stderr.append(data)
                self?.recordStderrTail(data)
            }
        }
        process.terminationHandler = { [closed, exitStatus] proc in
            out.readabilityHandler = nil
            err.readabilityHandler = nil
            // 正常退出时 ssh 子进程退出码即远端命令/shell 的退出码（信号终止则不采用）。
            if proc.terminationReason == .exit {
                exitStatus.set(proc.terminationStatus)
            }
            closed.fire()
        }

        do {
            try process.run()
        } catch {
            throw SSHExecError.connectFailed("无法启动系统 ssh：\(error.localizedDescription)")
        }

        lock.lock()
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        lock.unlock()

        // 早期失败探测：ssh 因网络 / 认证问题退出得很快，最多等 2 秒；期间仍在运行则视为
        // 连接正常（个别慢失败会在首次执行时才暴露，届时 stderr 会带回原因）。
        for _ in 0..<20 {
            if !process.isRunning {
                throw SSHExecError.connectFailed(failureSummary)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func write(_ text: String) {
        lock.lock()
        let handle = stdinHandle
        lock.unlock()
        guard let handle else { return }
        try? handle.write(contentsOf: Data(text.utf8))
    }

    func shutdown() {
        lock.lock()
        let proc = process
        let stdin = stdinHandle
        process = nil
        stdinHandle = nil
        lock.unlock()
        try? stdin?.close()
        if let proc, proc.isRunning { proc.terminate() }
        closed.fire()
    }

    private var failureSummary: String {
        lock.lock()
        let tail = String(decoding: stderrTail, as: UTF8.self)
        lock.unlock()
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "系统 ssh 已退出" : trimmed
    }

    private func recordStderrTail(_ data: Data) {
        lock.lock()
        stderrTail.append(data)
        if stderrTail.count > 4096 { stderrTail.removeFirst(stderrTail.count - 4096) }
        lock.unlock()
    }
}

// MARK: - 会话（标记协议执行）

/// 一条已建立连接上的命令执行器。actor 隔离天然串行化 run，且在 run 挂起（轮询睡眠）期间
/// 允许 close() 插入执行 —— close 置失效 + shutdown 后，run 的下一轮轮询即感知并返回。
actor SSHExecSession {
    /// 单流原始累积上限：超过视为失控命令，关闭会话。
    private static let rawCap = 2 * 1024 * 1024
    /// 单流返回上限：超出部分丢弃（保留头部）。
    private static let returnCap = 512 * 1024
    private static let pollIntervalNanos: UInt64 = 20_000_000 // 20ms

    private let transport: SSHExecTransport
    private var alive = false
    private var launched = false

    init(transport: SSHExecTransport) {
        self.transport = transport
    }

    /// 建连 + 排空登录横幅；cwd 非空则校验目录存在（失败抛错，会话随之关闭）。
    func launch(cwd: String?) async throws {
        guard !launched else { return }
        do {
            try await transport.launch()
            launched = true
            alive = true
        } catch {
            transport.shutdown()
            throw error
        }
        // 排空连接建立期的横幅 / MOTD（无 pty 时通常没有，稳妥起见丢弃）。
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = transport.stdout.consume()
        _ = transport.stderr.consume()

        if let cwd, !cwd.trimmingCharacters(in: .whitespaces).isEmpty {
            do {
                let check = await runInternal(command: "cd -- \(SSHProfile.shellQuote(cwd))",
                                              timeout: 15)
                if check.exitCode != 0 {
                    throw SSHExecError.badWorkingDirectory(
                        check.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } catch {
                closeInternal()
                throw error
            }
        }
    }

    /// 执行一条命令（可含换行的多行脚本）。会话失效时抛 `sessionClosed`。
    func run(command: String, timeout: TimeInterval) async throws -> SSHExecResult {
        guard alive else { throw SSHExecError.sessionClosed }
        return await runInternal(command: command, timeout: timeout)
    }

    func close() {
        closeInternal()
    }

    var isAlive: Bool { alive }

    // MARK: - 私有

    private func closeInternal() {
        alive = false
        transport.shutdown()
    }

    private func runInternal(command: String, timeout: TimeInterval) async -> SSHExecResult {
        let marker = "__DK" + Self.randomMarker() + "__"
        // 命令行 + 标记行：`$?` 取到的是命令（组）的退出码。
        let normalized = command.trimmingCharacters(in: .newlines)
        transport.write(normalized + "\n")
        transport.write("echo \(marker):$?\n")

        var stdoutRaw = Data()
        var stderrRaw = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var truncated = false

        while true {
            stdoutRaw.append(transport.stdout.consume())
            stderrRaw.append(transport.stderr.consume())

            if let hit = Self.scanMarker(marker, in: stdoutRaw) {
                return Self.makeResult(exitCode: hit.code,
                                        stdout: stdoutRaw, stderr: stderrRaw,
                                        truncated: truncated,
                                        timedOut: false, shellExited: false,
                                        stdoutCut: hit.lineStart)
            }

            if transport.closed.isFired {
                // shell 已退出（ssh 报错 / 远端登出 / 断线 / 命令以 exit 结束）。
                // 标记行没机会执行时，用传输层记录的 shell 退出码兜底；稍作等待以缩小
                // 「通道已关、退出码事件还在路上」的窗口。
                try? await Task.sleep(nanoseconds: 150_000_000)
                return Self.makeResult(exitCode: transport.exitStatus.get(),
                                        stdout: stdoutRaw, stderr: stderrRaw,
                                        truncated: truncated,
                                        timedOut: false, shellExited: true,
                                        stdoutCut: stdoutRaw.count)
            }

            if Date() >= deadline {
                // 超时：会话可能还挂着前台进程，无法安全续用，直接关闭。
                closeInternal()
                return Self.makeResult(exitCode: nil,
                                        stdout: stdoutRaw, stderr: stderrRaw,
                                        truncated: truncated,
                                        timedOut: true, shellExited: false,
                                        stdoutCut: stdoutRaw.count)
            }

            if stdoutRaw.count > Self.rawCap || stderrRaw.count > Self.rawCap {
                closeInternal()
                return Self.makeResult(exitCode: nil,
                                        stdout: stdoutRaw, stderr: stderrRaw,
                                        truncated: true,
                                        timedOut: false, shellExited: false,
                                        stdoutCut: min(stdoutRaw.count, Self.returnCap))
            }

            try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
        }
    }

    /// 在累积的 stdout 里找 `marker:<code>` 行；返回退出码与该行行首偏移（即输出截断点）。
    /// 偏移一律基于 `data.startIndex`（本文件里 Data 均为全新构造，startIndex == 0）。
    private static func scanMarker(_ marker: String, in data: Data) -> (code: Int32, lineStart: Int)? {
        let markerBytes = Data(marker.utf8)
        guard let markerRange = data.range(of: markerBytes) else { return nil }
        let base = data.startIndex

        var cursor = markerRange.upperBound
        guard cursor < data.endIndex, data[cursor] == UInt8(ascii: ":") else { return nil }
        cursor = data.index(after: cursor)

        var codeDigits = [UInt8]()
        while cursor < data.endIndex {
            let b = data[cursor]
            if b == UInt8(ascii: "\n") || b == UInt8(ascii: "\r") { break }
            guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") else { return nil }
            codeDigits.append(b)
            cursor = data.index(after: cursor)
        }
        guard !codeDigits.isEmpty,
              let code = Int32(String(decoding: codeDigits, as: UTF8.self)) else { return nil }

        var lineStart = markerRange.lowerBound
        while lineStart > base {
            let prev = data[data.index(before: lineStart)]
            if prev == UInt8(ascii: "\n") || prev == UInt8(ascii: "\r") { break }
            lineStart = data.index(before: lineStart)
        }
        return (code, lineStart - base)
    }

    private static func makeResult(exitCode: Int32?,
                                   stdout: Data, stderr: Data,
                                   truncated: Bool, timedOut: Bool, shellExited: Bool,
                                   stdoutCut: Int) -> SSHExecResult {
        let base = stdout.startIndex
        let cut = min(stdoutCut, stdout.count)
        var effectiveTruncated = truncated
        var outData = stdout.subdata(in: base..<base + cut)
        if outData.count > returnCap {
            outData = outData.prefix(returnCap)
            effectiveTruncated = true
        }
        var errData = stderr
        if errData.count > returnCap {
            errData = errData.prefix(returnCap)
            effectiveTruncated = true
        }
        return SSHExecResult(
            exitCode: exitCode,
            stdoutText: String(decoding: outData, as: UTF8.self),
            stderrText: String(decoding: errData, as: UTF8.self),
            truncated: effectiveTruncated,
            timedOut: timedOut,
            shellExited: shellExited
        )
    }

    private static func randomMarker() -> String {
        String(format: "%08x", UInt32.random(in: UInt32.min...UInt32.max))
    }
}

// MARK: - 会话注册表（主 actor）

/// 持久会话与一次性执行的统一入口：引擎选择、TOFU 门控、会话生命周期治理。
/// 真实凭据只在 `makeTransport`（主 actor 内）经过，随后封进 nonisolated 传输对象，不再外流。
@MainActor
final class SSHSessionRegistry {
    static let shared = SSHSessionRegistry()

    struct SessionSummary: Codable {
        let sessionId: UUID
        let server: String
        let authKind: String
        let idleSeconds: Int
    }

    private struct ManagedSession {
        let session: SSHExecSession
        let serverName: String
        let authKind: SSHAuthKind
        let openedAt: Date
        var lastUsed: Date
    }

    private var sessions: [UUID: ManagedSession] = [:]

    private static let maxSessions = 8
    private static let idleTimeout: TimeInterval = 30 * 60
    private static let maxLifetime: TimeInterval = 2 * 60 * 60

    nonisolated static let defaultExecTimeout: TimeInterval = 30
    nonisolated static let minExecTimeout: TimeInterval = 5
    nonisolated static let maxExecTimeout: TimeInterval = 600

    /// 参数钳制。
    nonisolated static func clampTimeout(_ value: Double?) -> TimeInterval {
        guard let value else { return defaultExecTimeout }
        return min(max(value, minExecTimeout), maxExecTimeout)
    }

    // MARK: - 持久会话

    /// 打开持久会话；cwd 非空时会话落在该目录（目录不存在则报错）。
    func openSession(profile: SSHProfile, cwd: String?) async throws -> UUID {
        guard sessions.count < Self.maxSessions else { throw SSHExecError.sessionLimitReached }
        let transport = try makeTransport(for: profile)
        let session = SSHExecSession(transport: transport)
        let effectiveCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            ? nil : cwd
        do {
            try await session.launch(cwd: effectiveCWD)
        } catch {
            // 失败即移除，不占会话名额。
            throw error
        }
        let id = UUID()
        sessions[id] = ManagedSession(session: session,
                                      serverName: profile.name,
                                      authKind: profile.authKind,
                                      openedAt: .now,
                                      lastUsed: .now)
        return id
    }

    /// 在持久会话上执行命令。
    func exec(sessionID: UUID, command: String, timeout: TimeInterval) async throws -> SSHExecResult {
        guard var managed = sessions[sessionID] else { throw SSHExecError.sessionNotFound }
        do {
            let result = try await managed.session.run(command: command, timeout: timeout)
            managed.lastUsed = .now
            sessions[sessionID] = managed
            if result.shellExited || result.timedOut {
                // 会话已被执行协议关闭，同步移除登记。
                sessions[sessionID] = nil
            }
            return result
        } catch {
            sessions[sessionID] = nil
            throw error
        }
    }

    /// 关闭指定会话（幂等）。
    func close(sessionID: UUID) async {
        guard let managed = sessions.removeValue(forKey: sessionID) else { return }
        await managed.session.close()
    }

    /// 一次性执行：内部临时会话，跑完即关。cwd 仅作用于本次执行（先 cd 校验再跑命令）。
    func execOneShot(profile: SSHProfile, command: String, cwd: String?, timeout: TimeInterval) async throws -> SSHExecResult {
        let transport = try makeTransport(for: profile)
        let session = SSHExecSession(transport: transport)
        let effectiveCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            ? nil : cwd
        do {
            try await session.launch(cwd: effectiveCWD)
        } catch {
            await session.close()
            throw error
        }
        let result = try await session.run(command: command, timeout: timeout)
        await session.close()
        return result
    }

    /// 空闲 / 存活期回收（由 AIAccessServer 的定时器驱动）。
    func reapIdle() async {
        let now = Date()
        let expired = sessions.filter { id, m in
            now.timeIntervalSince(m.lastUsed) > Self.idleTimeout ||
            now.timeIntervalSince(m.openedAt) > Self.maxLifetime
        }
        for (id, managed) in expired {
            sessions[id] = nil
            await managed.session.close()
        }
    }

    /// 全部关闭（服务停止 / app 退出）。
    func closeAll() async {
        let all = sessions
        sessions.removeAll()
        for (_, managed) in all {
            await managed.session.close()
        }
    }

    /// 活跃会话摘要（供 ssh_list_servers 返回；server 名经调用方脱敏）。
    var summaries: [SessionSummary] {
        let now = Date()
        return sessions.map { id, m in
            SessionSummary(sessionId: id,
                           server: m.serverName,
                           authKind: m.authKind.rawValue,
                           idleSeconds: Int(now.timeIntervalSince(m.lastUsed)))
        }
    }

    // MARK: - 引擎构造

    /// 密码认证 → 进程内 NIOSSH（要求主机已在 SSH 终端工具完成 TOFU 信任）；
    /// 私钥认证 → 系统 /usr/bin/ssh 子进程（与终端 / SFTP 工具的双引擎约定一致）。
    private func makeTransport(for profile: SSHProfile) throws -> SSHExecTransport {
        switch profile.authKind {
        case .password:
            guard SSHHostKeyStore.isTrusted(host: profile.host, port: profile.port) else {
                throw SSHExecError.hostNotTrusted
            }
            let auth = try SSHAuthSupport.makeUserAuthDelegate(for: profile)
            return NIOSSHExecTransport(host: profile.host, port: profile.port, auth: auth)
        case .key:
            guard let fileName = profile.privateKeyFileName,
                  let keyURL = SSHKeyStorage.resolvedURL(fileName: fileName) else {
                throw SSHExecError.keyMissing
            }
            let knownHosts = SSHKeyStorage.keysDirectoryURL()?
                .appendingPathComponent("ai_known_hosts").path ?? "/dev/null"
            return SystemSSHExecTransport(keyURL: keyURL,
                                          knownHostsPath: knownHosts,
                                          host: profile.host,
                                          port: profile.port,
                                          username: profile.username)
        }
    }
}
