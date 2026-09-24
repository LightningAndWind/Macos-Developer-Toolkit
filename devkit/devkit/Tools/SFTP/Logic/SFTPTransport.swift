//
//  SFTPTransport.swift
//  devkit
//
//  SFTP 的两种底层传输引擎，向 `SFTPCore` 提供「发整包 / 收整包」：
//   - `NIOSSHSFTPTransport`：进程内 NIOSSH（密码认证）。自动登录、应用内 TOFU。
//   - `SystemSSHTransport`：系统 `/usr/bin/ssh -s host sftp` 子进程（私钥认证）。
//     把 sftp-server 的线上协议接到进程 stdin/stdout，认证/主机校验交给 OpenSSH，
//     因而原生支持 RSA（boot.pem）、OpenSSH/加密私钥等 NIOSSH 解析不了的格式。
//
//  两者都只负责搬运「4 字节长度前缀 + body」的整包，SFTP 语义一律由 SFTPCore 处理。
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// 底层传输：把封帧后的整包发出去，并把收到的整包喂给 `core`。
nonisolated protocol SFTPTransport: AnyObject {
    /// 建立连接并把发送/关停回调注入 `core`。失败时抛出并自行回收已占资源。
    func start(core: SFTPCore) async throws

    /// 失败时的更具体诊断（如系统 ssh 的 stderr）；无则 nil。
    var failureSummary: String? { get }
}

// MARK: - 进程内 NIOSSH（密码认证）

/// 用 NIOSSH 连主机 → 开 session 子通道 → 激活 sftp 子系统，字节流经 `SFTPChannelHandler` 切帧。
nonisolated final class NIOSSHSFTPTransport: SFTPTransport, @unchecked Sendable {
    private let profile: SSHProfile
    private let auth: NIOSSHClientUserAuthenticationDelegate

    init(profile: SSHProfile, auth: NIOSSHClientUserAuthenticationDelegate) {
        self.profile = profile
        self.auth = auth
    }

    var failureSummary: String? { nil }

    func start(core: SFTPCore) async throws {
        let auth = self.auth
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var conn: Channel?
        var child: Channel?
        do {
            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let ssh = NIOSSHHandler(
                            role: .client(.init(userAuthDelegate: auth,
                                                serverAuthDelegate: AcceptAllHostKeysDelegate())),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandler(ssh)
                    }
                }
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

            let connection = try await bootstrap.connect(host: profile.host, port: profile.port).get()
            conn = connection

            let channel = try await Self.openSFTPChannel(on: connection, core: core)
            child = channel

            core.setTransport(
                send: { bytes in
                    channel.eventLoop.execute {
                        var buffer = channel.allocator.buffer(capacity: bytes.count)
                        buffer.writeBytes(bytes)
                        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)),
                                              promise: nil)
                    }
                },
                terminate: {
                    channel.close(mode: .all, promise: nil)
                    connection.close(mode: .all, promise: nil)
                    try? group.syncShutdownGracefully()
                }
            )
        } catch {
            child?.close(mode: .all, promise: nil)
            conn?.close(mode: .all, promise: nil)
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    /// 在连接上创建 session 子通道并激活 sftp 子系统。createChannel 只能在连接事件循环上调用，
    /// 故经 pipeline.handler + flatMap 的 future 回调执行（同 SSHClient.openShell）。
    private static func openSFTPChannel(on conn: Channel, core: SFTPCore) async throws -> Channel {
        try await conn.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let promise = conn.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise, channelType: .session) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(
                        // 弱引用 core：否则 core→(send/terminate)→child→pipeline→handler→core 形环，
                        // 标签关闭后 core/NIO 缓冲与事件循环无法释放。
                        SFTPChannelHandler(onFrame: { [weak core] in core?.handleFrame($0) },
                                           onClose: { [weak core] in core?.channelDidClose() })
                    )
                }
            }
            return promise.futureResult
        }.get()
    }
}

/// 主机密钥已在连接前按 host:port 维度完成 TOFU 询问，故此处直接放行。
private nonisolated final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    nonisolated func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

/// SFTP 子通道处理器：激活时触发 SubsystemRequest("sftp")；
/// 把远端字节流按「4 字节长度前缀」切分成完整 SFTP 包交给核心。
private nonisolated final class SFTPChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData

    /// 单包上限 64MB：超过视为协议错乱，直接断开。
    private static let maxFrameLength = 64 * 1024 * 1024

    private var buffer = ByteBuffer()
    private let onFrame: @Sendable ([UInt8]) -> Void
    private let onClose: @Sendable () -> Void

    init(onFrame: @escaping @Sendable ([UInt8]) -> Void,
         onClose: @escaping @Sendable () -> Void) {
        self.onFrame = onFrame
        self.onClose = onClose
    }

    nonisolated func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: false),
            promise: nil
        )
        context.fireChannelActive()
    }

    nonisolated func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .channel = channelData.type,
              case .byteBuffer(var incoming) = channelData.data else {
            context.fireChannelRead(data)
            return
        }
        buffer.writeBuffer(&incoming)

        while true {
            guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else { break }
            guard length >= 1, Int(length) <= Self.maxFrameLength else {
                context.close(promise: nil)
                return
            }
            guard buffer.readableBytes >= 4 + Int(length) else { break }
            buffer.moveReaderIndex(forwardBy: 4)
            guard let frame = buffer.readBytes(length: Int(length)) else { break }
            onFrame(frame)
        }
    }

    nonisolated func channelInactive(context: ChannelHandlerContext) {
        onClose()
        context.fireChannelInactive()
    }

    nonisolated func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - 系统 ssh 子进程（私钥认证）

/// 运行 `/usr/bin/ssh -s <host> sftp`，把 sftp-server 的线上协议接到进程管道上。
/// stdout 按「4 字节长度前缀」切帧喂给 core；封帧后的整包写进 stdin。
nonisolated final class SystemSSHTransport: SFTPTransport, @unchecked Sendable {
    private static let maxFrameLength = 64 * 1024 * 1024

    private let profile: SSHProfile
    private let keyURL: URL
    private let knownHostsPath: String

    private let lock = NSLock()
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var stdinHandle: FileHandle?
    nonisolated(unsafe) private var stdoutHandle: FileHandle?
    nonisolated(unsafe) private var stderrHandle: FileHandle?
    private var recvBuf: [UInt8] = []
    private var stderrData = Data()
    private var finished = false

    init(profile: SSHProfile, keyURL: URL, knownHostsPath: String) {
        self.profile = profile
        self.keyURL = keyURL
        self.knownHostsPath = knownHostsPath
    }

    func start(core: SFTPCore) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.sshArguments(profile: profile,
                                              keyURL: keyURL,
                                              knownHostsPath: knownHostsPath)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let out = stdoutPipe.fileHandleForReading
        let err = stderrPipe.fileHandleForReading

        out.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                self?.finish(core: core)
                return
            }
            self?.ingest([UInt8](data), core: core)
        }
        err.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderr(data)
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish(core: core)
        }

        do {
            try process.run()
        } catch {
            out.readabilityHandler = nil
            err.readabilityHandler = nil
            throw SFTPError.serverError(code: 255,
                                        message: "无法启动系统 ssh：\(error.localizedDescription)")
        }

        lock.lock()
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = out
        self.stderrHandle = err
        lock.unlock()

        core.setTransport(
            send: { [weak self] bytes in self?.write(bytes) },
            terminate: { [weak self] in self?.shutdown() }
        )
    }

    var failureSummary: String? {
        lock.lock()
        let data = stderrData
        lock.unlock()
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    // MARK: 帧收发

    private func write(_ bytes: [UInt8]) {
        lock.lock()
        let handle = stdinHandle
        lock.unlock()
        guard let handle else { return }
        try? handle.write(contentsOf: Data(bytes))
    }

    private func ingest(_ chunk: [UInt8], core: SFTPCore) {
        var frames: [[UInt8]] = []
        var corrupt = false
        lock.lock()
        recvBuf.append(contentsOf: chunk)
        extractLoop: while true {
            guard recvBuf.count >= 4 else { break }
            let length = UInt32(recvBuf[0]) &<< 24 | UInt32(recvBuf[1]) &<< 16
                | UInt32(recvBuf[2]) &<< 8 | UInt32(recvBuf[3])
            guard length >= 1, length <= UInt32(Self.maxFrameLength) else { corrupt = true; break }
            let total = 4 + Int(length)
            guard recvBuf.count >= total else { break }
            frames.append(Array(recvBuf[4..<total]))
            recvBuf.removeFirst(total)
            continue extractLoop
        }
        if corrupt { recvBuf.removeAll() }
        lock.unlock()

        for frame in frames {
            core.handleFrame(frame)
        }
        if corrupt { core.channelDidClose() }
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        stderrData.append(data)
        // 只保留尾部，避免异常刷屏时占用过多内存。
        if stderrData.count > 8192 { stderrData.removeFirst(stderrData.count - 8192) }
        lock.unlock()
    }

    private func finish(core: SFTPCore) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let out = stdoutHandle
        let err = stderrHandle
        lock.unlock()
        out?.readabilityHandler = nil
        err?.readabilityHandler = nil
        core.channelDidClose()
    }

    private func shutdown() {
        lock.lock()
        finished = true
        let proc = process
        let stdin = stdinHandle
        let out = stdoutHandle
        let err = stderrHandle
        process = nil
        stdinHandle = nil
        lock.unlock()
        out?.readabilityHandler = nil
        err?.readabilityHandler = nil
        try? stdin?.close()
        if let proc, proc.isRunning { proc.terminate() }
    }

    /// 组装 `ssh` 参数：仅走公钥、非交互（认证失败即退出而非挂起等待口令/密码）、
    /// 首次连接自动写入应用私有的 known_hosts（不污染用户 `~/.ssh`）。
    private static func sshArguments(profile: SSHProfile, keyURL: URL, knownHostsPath: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-o", "ConnectTimeout=15",
            "-i", keyURL.path,
            "-p", String(profile.port),
            "-s",
            "\(profile.username)@\(profile.host)",
            "sftp",
        ]
    }
}
