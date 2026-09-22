//
//  SSHClient.swift
//  devkit
//
//  M4：基于 NIOSSH 的进程内 SSH 客户端。保持 App Sandbox（网络经 network.client）。
//  连接 → 认证（密码 / PEM 私钥）→ 打开 session 通道 → 申请 pty + shell。
//  远端输出经 AsyncStream 交主线程喂给 SwiftTerm；本地键入经 write(_:) 下发；resize 发窗口变更。
//
//  注意：工程默认 actor 隔离为 MainActor，故所有被 NIO 从事件循环调用的类型（处理器 / 委托）
//  显式标注 nonisolated + @unchecked Sendable，可变共享状态用锁或 nonisolated(unsafe) 保护。
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import CryptoKit

/// 一个远程 SSH 终端会话的传输对象。仅在主 actor 使用其公开接口。
@MainActor
@Observable
final class SSHClient {
    // MARK: - 对外状态

    private(set) var state: SSHConnectionState = .idle

    /// 首连信任询问回调（TOFU，host:port 维度）。返回 true 表示信任并继续。
    var trustHandler: ((String, Int) async -> Bool)?

    /// 远端输出字节流；视图侧消费后 feed 给终端。
    let incoming: AsyncStream<[UInt8]>
    private let outputContinuation: AsyncStream<[UInt8]>.Continuation

    // MARK: - NIO 内部

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var outputTask: Task<Void, Never>?

    /// NIO 侧的可变状态（通道 / 关闭信号）集中放在这里，理由见 `NIOResources` 的注释。
    private let nio = NIOResources()

    init() {
        var cont: AsyncStream<[UInt8]>.Continuation!
        self.incoming = AsyncStream { cont = $0 }
        self.outputContinuation = cont
    }

    // MARK: - 连接

    /// 连接并进入交互 shell。失败/拒绝信任时更新 `state`，不抛出。
    func connect(profile: SSHProfile, cols: Int, rows: Int) async {
        guard !state.isLive else { return }
        state = .connecting

        // TOFU：未信任主机先询问；拒绝则中止。
        if !SSHHostKeyStore.isTrusted(host: profile.host, port: profile.port) {
            let trusted = await (trustHandler?(profile.host, profile.port) ?? false)
            guard trusted else {
                state = .failed("未信任该主机，连接已取消")
                return
            }
            SSHHostKeyStore.trust(host: profile.host, port: profile.port)
        }

        do {
            let auth = try makeUserAuthDelegate(for: profile)

            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let ssh = NIOSSHHandler(
                            role: .client(
                                .init(userAuthDelegate: auth,
                                      serverAuthDelegate: AcceptAllHostKeysDelegate())
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandler(ssh)
                    }
                }
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

            let conn = try await bootstrap.connect(host: profile.host, port: profile.port).get()
            nio.connectionChannel = conn

            // 本次连接专属的关闭信号；onClose 直接捕获它（AsyncSignal 是 Sendable），
            // 这样既不受重连影响，也免去一次「hop 回主线程再读信号」的绕路。
            let signal = AsyncSignal()
            nio.closeSignal = signal

            let shell = try await Self.openShell(on: conn, cols: cols, rows: rows,
                                                 output: { [weak self] bytes in
                                                     self?.outputContinuation.yield(bytes)
                                                 },
                                                 onClose: { signal.fire() })
            nio.shellChannel = shell
            state = .connected(host: profile.host)

            watchClose(signal)
        } catch {
            teardownChannels()
            state = .failed(error.localizedDescription)
        }
    }

    /// 用户断开或标签关闭时调用。
    ///
    /// **不要在这里 `outputContinuation.finish()`** —— `AsyncStream` 的 `finish()` 是终态，
    /// 之后所有 `yield` 都会被静默丢弃。而消费端（`SSHTerminalContainer.Coordinator`）
    /// 只在视图首次出现时订阅一次，于是「断开 → 重新连接」「换个目标」之后，
    /// 新会话的远端输出会全部被丢掉 —— 表现为**终端再也不显示任何内容**（但连接其实是好的）。
    /// 输出流的生命周期应跟随 client 而非单次连接：消费任务靠视图 `dismantleNSView` 里
    /// 的 `cancel()` 结束，client 释放时 continuation 一起释放、流自然终止。
    func disconnect() {
        outputTask?.cancel()
        outputTask = nil
        teardownChannels()
        if case .idle = state { } else { state = .disconnected }
    }

    /// 会话从快照恢复时把状态标记为「已断开」：回填了连接配置但不自动联网，
    /// 交由横幅展示「重新连接」按钮由用户点击触发（避免启动即 surprise 联网）。
    func markRestoredDisconnected() {
        state = .disconnected
    }

    // MARK: - I/O

    /// 把本地键入字节写入远端 stdin。
    func write(_ bytes: [UInt8]) {
        guard let shell = nio.shellChannel else { return }
        var buffer = shell.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        shell.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    }

    /// 终端尺寸变化 → 发送窗口变更请求。
    /// SwiftTerm 在视图刚创建 / 尺寸未定时可能回报 0 甚至负值，NIOSSH 事件内部转 UInt32 会 trap，故限幅 ≥ 1。
    func resize(cols: Int, rows: Int) {
        guard let shell = nio.shellChannel else { return }
        let width = max(cols, 1)
        let height = max(rows, 1)
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: width,
            terminalRowHeight: height,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        shell.eventLoop.execute {
            shell.triggerUserOutboundEvent(event, promise: nil)
        }
    }

    // MARK: - Private

    /// 构造认证委托（主 actor）：密码用内置 SimplePasswordDelegate；私钥解析 PEM 后自定义。
    private func makeUserAuthDelegate(for profile: SSHProfile) throws -> NIOSSHClientUserAuthenticationDelegate {
        switch profile.authKind {
        case .password:
            return SimplePasswordDelegate(username: profile.username,
                                          password: profile.password ?? "")
        case .key:
            guard let fileName = profile.privateKeyFileName,
                  let url = SSHKeyStorage.resolvedURL(fileName: fileName) else {
                throw SSHClientError.privateKeyMissing
            }
            let pem = try String(contentsOf: url, encoding: .utf8)
            let key = try Self.parsePrivateKey(pem: pem, passphrase: profile.keyPassphrase)
            return PrivateKeyAuthDelegate(username: profile.username, privateKey: key)
        }
    }

    /// 用 CryptoKit 解析 PEM（PKCS#8）私钥。本期仅支持未加密的 NIST ECDSA（P-256/384/521）PEM；
    /// 含口令的加密 PEM 与 OpenSSH 原生格式暂不支持（会抛出明确错误）。
    private nonisolated static func parsePrivateKey(pem: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        _ = passphrase // 加密私钥暂不支持；unencrypted 解析失败即报不支持。
        if let k = try? P256.Signing.PrivateKey(pemRepresentation: pem) { return NIOSSHPrivateKey(p256Key: k) }
        if let k = try? P384.Signing.PrivateKey(pemRepresentation: pem) { return NIOSSHPrivateKey(p384Key: k) }
        if let k = try? P521.Signing.PrivateKey(pemRepresentation: pem) { return NIOSSHPrivateKey(p521Key: k) }
        throw SSHClientError.privateKeyUnsupported
    }

    /// 在已建立的连接上创建 session 子通道并进入 shell。
    ///
    /// 必须把建通道的动作放进「连接事件循环上的 future 回调」里，两个原因缺一不可：
    /// 1. `NIOSSHHandler.createChannel` 文档明确写着「not thread-safe: may only be called from on the channel」，
    ///    它内部直接往 `pendingChannelInitializations` 这个 Deque 里塞元素，从主线程调用是数据竞争；
    /// 2. 传入的 `channelInitializer` 里用的是 `eventLoop.makeCompletedFuture`，它会**在调用线程上就地执行**闭包
    ///    （见 NIOCore：`Result(catching: body)`），于是 `pipeline.syncOperations.addHandler` 就在非事件循环线程上
    ///    撞上 NIO 的 `assertInEventLoop` 断言 —— 即 `EventLoop.preconditionInEventLoop` 崩溃。
    ///
    /// 用 `flatMap` 而不是 `eventLoop.execute`：`EventLoopFuture._internalWhenComplete` 里明确
    /// `inEventLoop ? 就地执行 : eventLoop.execute { … }`，所以 future 回调**保证**跑在所属事件循环上，
    /// 同时 `sshHandler` 是回调入参而非捕获值，不会产生 non-Sendable 捕获告警。
    private nonisolated static func openShell(on conn: Channel,
                                             cols: Int,
                                             rows: Int,
                                             output: @escaping @Sendable ([UInt8]) -> Void,
                                             onClose: @escaping @Sendable () -> Void) async throws -> Channel {
        try await conn.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let promise = conn.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise, channelType: .session) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(
                        SSHShellHandler(cols: cols, rows: rows, onOutput: output, onClose: onClose)
                    )
                }
            }
            return promise.futureResult
        }.get()
    }

    /// 监听远端关闭：只捕获本次连接的 `signal`，**不跨挂起点强持有 self**。
    ///
    /// 关键：写成 `Task { [weak self] in guard let self else { return }; await self.closeSignal.wait() }` 时，
    /// `guard let self` 会把 SSHClient 在整个挂起期间强钉住。关标签走的是 `TabManager.close`，
    /// 它只把 Tab 从数组里移除、**没有任何断开钩子**，于是 Tab / SSHTool 都释放了、SSHClient 却因这个
    /// 永久挂起的 Task 永不 deinit —— 事件循环线程与 TCP 连接一起泄漏（正是 `deinit` 里那句
    /// `group.syncShutdownGracefully()` 从未执行的原因）。
    private func watchClose(_ signal: AsyncSignal) {
        outputTask = Task { [weak self] in
            await signal.wait()
            guard let self else { return }
            guard case .connected = self.state else { return }
            self.state = .disconnected
        }
    }

    private func teardownChannels() {
        nio.shellChannel?.close(mode: .all, promise: nil)
        nio.shellChannel = nil
        nio.connectionChannel?.close(mode: .all, promise: nil)
        nio.connectionChannel = nil
    }

    deinit {
        // 收尾只能委托给 `nio`（nonisolated 引用类型）：本类是 @Observable + MainActor，
        // deinit 既读不到 MainActor 隔离的属性，读到了也会走 Observation 的 access(keyPath:)，
        // 而对象此刻正在析构 —— 都不安全。`group` 是 Sendable 的 let，可以直接读。
        nio.teardown(group: group)
    }
}

/// NIO 侧的可变状态（通道 / 关闭信号）与收尾逻辑。
///
/// 单独抽出来是为了让 `SSHClient.deinit` 能安全收尾：
/// - `SSHClient` 是 `@Observable`，其存储属性会被宏改写成「计算属性 + `_xxx` 存储」，
///   在 deinit 里读它会触发 Observation 的 `access(keyPath:)`，对象正在析构、不安全；
///   而且宏也不允许给这些属性加 `nonisolated`。
/// - `SSHClient` 又是 `@MainActor` 隔离的，nonisolated 的 deinit 根本读不到它的可变属性。
/// 放进本类后，deinit 读的就是普通存储属性，且不受 actor 隔离约束。
private nonisolated final class NIOResources: @unchecked Sendable {
    var connectionChannel: Channel?
    var shellChannel: Channel?

    /// 当前连接的关闭信号。**每次连接都换新的**（见 `SSHClient.connect`）：
    /// `AsyncSignal.fired` 是单向闩锁，若整条连接共用同一个实例，上一次断开时已经触发过的信号
    /// 会让重连后的 `watchClose` 立刻返回，把刚连上的会话误判为 `.disconnected`。
    var closeSignal = AsyncSignal()

    /// 放行挂起的监听任务 → 关通道 → 关事件循环组。**顺序不能反**：
    /// NIO 的 `BaseSocketChannel.deinit` 会断言 `canBeDestroyed`（即通道必须已 closed），
    /// 带着未关闭的通道析构会在 Debug 下直接崩在 "leak of open Channel"；
    /// 而 `syncShutdownGracefully()` 会等事件循环把 close 处理完，之后通道析构才是安全的。
    func teardown(group: MultiThreadedEventLoopGroup) {
        // deinit 期间 SSHClient 的 weak 引用已是 nil，被放行的监听任务会立即返回并释放，
        // 不至于把一个挂起的 Task 一直留到进程结束。
        closeSignal.fire()
        shellChannel?.close(mode: .all, promise: nil)
        connectionChannel?.close(mode: .all, promise: nil)
        // 阻塞式收尾：会短暂占用调用线程（通常是主线程）。若后续发现关标签时有可感知卡顿，
        // 可换成非阻塞的 `group.shutdownGracefully { _ in }`。
        try? group.syncShutdownGracefully()
    }
}

// MARK: - NIO 侧类型（nonisolated）

/// session 子通道处理器：激活时申请 pty 并进入 shell；把远端数据转成 [UInt8] 上报。
private nonisolated final class SSHShellHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = Never

    private let cols: Int
    private let rows: Int
    private let onOutput: @Sendable ([UInt8]) -> Void
    private let onClose: @Sendable () -> Void

    init(cols: Int, rows: Int,
         onOutput: @escaping @Sendable ([UInt8]) -> Void,
         onClose: @escaping @Sendable () -> Void) {
        self.cols = cols
        self.rows = rows
        self.onOutput = onOutput
        self.onClose = onClose
    }

    nonisolated func channelActive(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)

        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: max(cols, 1),
            terminalRowHeight: max(rows, 1),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    nonisolated func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .channel = channelData.type,
              case .byteBuffer(var buffer) = channelData.data else {
            context.fireChannelRead(data)
            return
        }
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            onOutput(bytes)
        }
    }

    nonisolated func channelInactive(context: ChannelHandlerContext) {
        onClose()
        context.fireChannelInactive()
    }
}

/// 私钥认证委托：提供一次 privateKey offer，之后返回 nil。
private nonisolated final class PrivateKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private let lock = NSLock()
    nonisolated(unsafe) private var pending = true

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    nonisolated func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock(); let shouldOffer = pending && availableMethods.contains(.publicKey); pending = false; lock.unlock()
        if shouldOffer {
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: username, serviceName: "",
                                              offer: .privateKey(.init(privateKey: privateKey)))
            )
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}

/// 主机密钥已在连接前按 host:port 维度完成 TOFU 询问，故此处直接放行。
private nonisolated final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    nonisolated func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

/// 一次性触发的异步信号：把「通道已关闭」事件从 NIO 事件循环线程传到等待中的任务。
///
/// `fired` 是**单向闩锁**：触发后所有等待者立即返回，且之后的 `wait()` 也立即返回。
/// 因此每条连接必须持有独立实例（见 `SSHClient.connect`），否则重连会被上一次的已触发状态污染。
nonisolated final class AsyncSignal: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var fired = false
    nonisolated(unsafe) private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        for c in waiters { c.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                c.resume()
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }
}

enum SSHClientError: LocalizedError {
    case privateKeyMissing
    case privateKeyUnsupported
    var errorDescription: String? {
        switch self {
        case .privateKeyMissing: return "找不到私钥文件，请重新选择"
        case .privateKeyUnsupported: return "暂不支持该私钥（本期仅支持未加密的 PKCS#8 PEM ECDSA 密钥；含口令或 OpenSSH 原生格式请先转换）"
        }
    }
}
