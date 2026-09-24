//
//  SFTPConnection.swift
//  devkit
//
//  SFTP v3 客户端门面：连接 → 认证 → 打开 sftp 通道 → INIT/VERSION 握手 → 请求应答（按 request-id 配对）。
//
//  引擎按认证方式分流（与 SSH 终端一致）：
//   - 密码认证 → 进程内 NIOSSH（`NIOSSHSFTPTransport`）；主机信任沿用 SSH 终端 TOFU 存储。
//   - 私钥认证 → 系统 `/usr/bin/ssh -s host sftp` 子进程（`SystemSSHTransport`）：原生支持
//     RSA（如 boot.pem）、OpenSSH/口令等 NIOSSH 无法解析的私钥格式。
//
//  两种引擎都把「发整包 / 收整包」通过 `SFTPCore.setTransport` 注入，`SFTPCore` 只负责
//  request-id 配对与编解码，不关心底层是 NIO 通道还是进程管道。
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

@MainActor
@Observable
final class SFTPConnection: SFTPBackend {
    typealias State = SFTPBackendState

    private(set) var state: State = .idle

    /// 协议核心（nonisolated，锁保护）。
    private let core = SFTPCore()

    /// 当前传输引擎（仅用于失败时取更具体的诊断信息）。
    private var transport: (any SFTPTransport)?

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: - 连接

    /// 连接并完成 SFTP 握手；失败时置 `.failed`，不抛出。
    func connect(profile: SSHProfile) async {
        guard !isConnectingOrConnected else { return }
        state = .connecting

        // 私钥认证走系统 ssh（自带主机校验），只需拿到私钥文件路径；
        // 密码认证走 NIOSSH，沿用应用内 TOFU：未信任主机给出明确指引。
        let engine: any SFTPTransport
        switch profile.authKind {
        case .key:
            guard let fileName = profile.privateKeyFileName,
                  let keyURL = SSHKeyStorage.resolvedURL(fileName: fileName) else {
                state = .failed("找不到私钥文件，请在「SSH 终端」里重新选择该连接的私钥。")
                return
            }
            let knownHosts = (SSHKeyStorage.keysDirectoryURL()?.appendingPathComponent("sftp_known_hosts").path)
                ?? (NSHomeDirectory() + "/.ssh/known_hosts")
            engine = SystemSSHTransport(profile: profile, keyURL: keyURL, knownHostsPath: knownHosts)
        case .password:
            guard SSHHostKeyStore.isTrusted(host: profile.host, port: profile.port) else {
                state = .failed("尚未信任主机 \(profile.host)。\n请先在「SSH 终端」工具中成功连接一次该主机完成首次信任确认，再回来使用 SFTP。")
                return
            }
            do {
                let auth = try SSHAuthSupport.makeUserAuthDelegate(for: profile)
                engine = NIOSSHSFTPTransport(profile: profile, auth: auth)
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }

        transport = engine
        core.setOnClosed { [weak self] in
            Task { @MainActor in self?.handleRemoteClose() }
        }

        do {
            try await engine.start(core: core)
            _ = try await core.initialize()
            state = .connected(host: profile.host)
        } catch {
            core.teardown()
            transport = nil
            let diagnostic = engine.failureSummary ?? error.localizedDescription
            state = .failed(diagnostic)
        }
    }

    /// 用户主动断开。
    func disconnect() {
        guard !isIdle else { return }
        core.teardown()
        transport = nil
        state = .disconnected
    }

    private var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    private var isConnectingOrConnected: Bool {
        switch state {
        case .connecting, .connected: return true
        default: return false
        }
    }

    /// 远端关闭（网络断开 / 服务器关闭通道）。
    private func handleRemoteClose() {
        if case .connected = state { state = .disconnected }
    }

    // MARK: - 目录与元数据

    /// REALPATH：把相对路径（如 "."）解析为绝对路径。
    func resolvePath(_ path: String = ".") async throws -> String {
        var writer = SFTPWriter()
        writer.writeString(path)
        let reply = try await core.request(.realpath, payload: writer.bytes)
        guard let names = try reply.expectNameList(), let first = names.first else {
            throw SFTPError.invalidPacket
        }
        return first.name
    }

    /// 列目录：OPENDIR → 循环 READDIR → CLOSE。
    func listDirectory(_ path: String) async throws -> [SFTPEntry] {
        var writer = SFTPWriter()
        writer.writeString(path)
        let handle = try await core.request(.opendir, payload: writer.bytes).expectHandle()

        var collected: [(name: String, longName: String, attrs: SFTPAttrs)] = []
        do {
            outer: while true {
                try Task.checkCancellation()
                let reply = try await core.request(.readdir, payload: handlePayload(handle))
                switch reply {
                case .name(let items):
                    collected.append(contentsOf: items)
                case .status(let code, let message):
                    if code == SFTPStatusCode.eof.rawValue { break outer }
                    if let error = SFTPError.fromStatus(code: code, message: message) { throw error }
                default:
                    throw SFTPError.invalidPacket
                }
            }
            try await closeHandle(handle)
        } catch {
            try? await closeHandle(handle) // 尽力归还远端句柄，避免句柄泄漏
            throw error
        }
        return collected
            .filter { $0.name != "." && $0.name != ".." }
            .map { SFTPEntry(name: $0.name, longName: $0.longName, attrs: $0.attrs) }
    }

    /// STAT（跟随符号链接）。
    func stat(_ path: String) async throws -> SFTPAttrs {
        var writer = SFTPWriter()
        writer.writeString(path)
        let reply = try await core.request(.stat, payload: writer.bytes)
        return try reply.expectAttrs()
    }

    func makeDirectory(_ path: String) async throws {
        var writer = SFTPWriter()
        writer.writeString(path)
        SFTPAttrs.encodeEmpty(into: &writer)
        try await core.request(.mkdir, payload: writer.bytes).expectOK()
    }

    func removeFile(_ path: String) async throws {
        var writer = SFTPWriter()
        writer.writeString(path)
        try await core.request(.remove, payload: writer.bytes).expectOK()
    }

    func removeDirectory(_ path: String) async throws {
        var writer = SFTPWriter()
        writer.writeString(path)
        try await core.request(.rmdir, payload: writer.bytes).expectOK()
    }

    // MARK: - 文件传输

    /// 下载远端文件到本地 URL（分块流式写盘 + 读前推流水线，支持取消与进度回调）。
    ///
    /// 吞吐瓶颈在于“每个分块一次往返”：高延迟链路上串行 await 会使速度 ≈ chunkSize / RTT。
    /// 这里同时挂起 `readWindow` 个 READ 请求（SFTP 按 request-id 配对，并发安全），
    /// 按偏移顺序消费，从而把有效带宽提高一个数量级。
    func downloadFile(_ remotePath: String,
                      to localURL: URL,
                      progress: ((UInt64, UInt64?) -> Void)? = nil) async throws {
        var writer = SFTPWriter()
        writer.writeString(remotePath)
        writer.writeUInt32(Self.pflagRead)
        SFTPAttrs.encodeEmpty(into: &writer)
        let handle = try await core.request(.open, payload: writer.bytes).expectHandle()

        let total = try? await stat(remotePath).size
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: localURL)
        defer { try? fileHandle.close() }

        let chunk = UInt64(Self.chunkSize)
        var issueOffset: UInt64 = 0
        var writeOffset: UInt64 = 0
        var hitEOF = false
        var inflight: [Task<[UInt8]?, Error>] = []

        // 进度回调节流：每 ~0.1s 最多上报一次，避免高频刷新拖垮 UI。
        var lastEmit = Date.distantPast
        func emit(force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastEmit) >= 0.1 else { return }
            lastEmit = now
            progress?(writeOffset, total)
        }
        func issueOne() {
            let off = issueOffset
            issueOffset &+= chunk
            inflight.append(Task { [self] in
                try await readChunk(handle: handle, offset: off, length: Self.chunkSize)
            })
        }

        do {
            while !hitEOF, inflight.count < Self.readWindow { issueOne() }
            while !inflight.isEmpty {
                try Task.checkCancellation()
                let data = try await inflight.removeFirst().value
                guard let data, !data.isEmpty else { hitEOF = true; break }
                try fileHandle.write(contentsOf: Data(data))
                writeOffset &+= UInt64(data.count)
                emit()
                if !hitEOF { issueOne() }
            }
            emit(force: true)
            try await closeHandle(handle)
        } catch {
            inflight.forEach { $0.cancel() }
            try? await closeHandle(handle)
            throw error
        }
    }

    /// 上传本地文件到远端路径（分块流式读盘 + 写前推流水线，支持取消与进度回调）。
    ///
    /// 写请求带显式偏移、服务端幂等可乱序应用，因此也可并发挂起 `writeWindow` 个。
    /// （窗口比读小，避免向系统 ssh 子进程的 stdin 灌太多数据时阻塞主线程。）
    func uploadFile(from localURL: URL,
                    to remotePath: String,
                    progress: ((UInt64, UInt64?) -> Void)? = nil) async throws {
        let total = ((try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size]) as? NSNumber)?.uint64Value

        var writer = SFTPWriter()
        writer.writeString(remotePath)
        writer.writeUInt32(Self.pflagWrite | Self.pflagCreate | Self.pflagTruncate)
        SFTPAttrs.encodeEmpty(into: &writer)
        let handle = try await core.request(.open, payload: writer.bytes).expectHandle()

        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }

        var readOffset: UInt64 = 0
        var doneBytes: UInt64 = 0
        var sawEOF = false
        var inflight: [(bytes: Int, task: Task<Void, Error>)] = []

        var lastEmit = Date.distantPast
        func emit(force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastEmit) >= 0.1 else { return }
            lastEmit = now
            progress?(doneBytes, total)
        }
        // 读取一块并挂起一个 WRITE（不等待应答）。
        func issueOneWrite() throws {
            guard let chunkData = try fileHandle.read(upToCount: Self.chunkSize), !chunkData.isEmpty else {
                sawEOF = true
                return
            }
            let off = readOffset
            let bytes = chunkData.count
            readOffset &+= UInt64(bytes)
            inflight.append((bytes, Task { [self] in
                try await writeChunk(handle: handle, offset: off, data: Array(chunkData))
            }))
        }

        do {
            while !sawEOF, inflight.count < Self.writeWindow { try issueOneWrite() }
            while !inflight.isEmpty {
                try Task.checkCancellation()
                let finished = inflight.removeFirst()
                try await finished.task.value
                doneBytes &+= UInt64(finished.bytes)
                emit()
                if !sawEOF { try issueOneWrite() }
            }
            emit(force: true)
            try await closeHandle(handle)
        } catch {
            inflight.forEach { $0.task.cancel() }
            try? await closeHandle(handle)
            throw error
        }
    }

    // MARK: - 内部

    private static let chunkSize = 32_768
    /// 下载并发挂起的 READ 数（× chunkSize = 在途字节），拉高有效带宽。
    private static let readWindow = 16
    /// 上传并发挂起的 WRITE 数；比读窗口小，避免向系统 ssh 子进程 stdin 灌太多卡住主线程。
    private static let writeWindow = 8
    private static let pflagRead = UInt32(0x1)
    private static let pflagWrite = UInt32(0x2)
    private static let pflagCreate = UInt32(0x8)
    private static let pflagTruncate = UInt32(0x10)

    private func closeHandle(_ handle: [UInt8]) async throws {
        try await core.request(.close, payload: handlePayload(handle)).expectOK()
    }

    /// 单个 READ：返回数据；EOF 时返回 nil。（供下载流水线并发调用）
    private func readChunk(handle: [UInt8], offset: UInt64, length: Int) async throws -> [UInt8]? {
        var read = SFTPWriter()
        read.writeBytes(handle) // handle 是 string 字段：带长度前缀
        read.writeUInt64(offset)
        read.writeUInt32(UInt32(length))
        let reply = try await core.request(.read, payload: read.bytes)
        return try reply.expectData()
    }

    /// 单个 WRITE（带显式偏移，服务端幂等）。（供上传流水线并发调用）
    private func writeChunk(handle: [UInt8], offset: UInt64, data: [UInt8]) async throws {
        var write = SFTPWriter()
        write.writeBytes(handle) // handle 是 string 字段：带长度前缀
        write.writeUInt64(offset)
        write.writeBytes(data)
        try await core.request(.write, payload: write.bytes).expectOK()
    }

    /// 句柄作为 SFTP `string` 字段写回 payload（uint32 长度前缀 + 原始字节）。
    private func handlePayload(_ handle: [UInt8]) -> [UInt8] {
        var writer = SFTPWriter()
        writer.writeBytes(handle)
        return writer.bytes
    }

    deinit {
        core.teardown()
    }
}

/// SFTP 协议核心：request-id 配对、包发送、应答分发。与底层传输解耦。
/// 所有可变状态在锁内；被传输层线程与主 actor 两侧调用。
nonisolated final class SFTPCore: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<SFTPReply, Error>] = [:]
    /// 每请求的超时看门狗 Task；应答一到就取消，避免大量睡 20s 的僵尸 Task 随传输堆积。
    private var timers: [UInt32: Task<Void, Never>] = [:]
    private var versionPending: CheckedContinuation<SFTPReply, Error>?

    /// 把「已封帧的整包」交给底层传输发送（NIO 通道 / 进程管道各自实现）。
    nonisolated(unsafe) private var sendPacket: (@Sendable ([UInt8]) -> Void)?
    /// 关停底层传输（关通道、结束进程、关停事件循环）。
    nonisolated(unsafe) private var terminateTransport: (@Sendable () -> Void)?
    nonisolated(unsafe) private var onClosed: (@Sendable () -> Void)?

    /// 单请求超时（秒）。
    private static let requestTimeout: Double = 20

    // MARK: 装配

    /// 注入传输层：`send` 收到封帧后的字节即整包；`terminate` 负责回收底层资源。
    func setTransport(send: @escaping @Sendable ([UInt8]) -> Void,
                      terminate: @escaping @Sendable () -> Void) {
        lock.lock()
        self.sendPacket = send
        self.terminateTransport = terminate
        lock.unlock()
    }

    func setOnClosed(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.onClosed = handler
        lock.unlock()
    }

    // MARK: 请求

    /// 发送一个带 request-id 的请求并等待配对应答。
    func request(_ type: SFTPPacketType, payload: [UInt8]) async throws -> SFTPReply {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SFTPReply, Error>) in
            let id: UInt32
            let send: (@Sendable ([UInt8]) -> Void)?
            lock.lock()
            id = nextID
            nextID &+= 1
            pending[id] = cont
            send = sendPacket
            lock.unlock()

            guard let send else {
                lock.lock()
                pending.removeValue(forKey: id)
                lock.unlock()
                cont.resume(throwing: SFTPError.connectionClosed)
                return
            }

            var body: [UInt8] = [type.rawValue]
            var idWriter = SFTPWriter()
            idWriter.writeUInt32(id)
            body.append(contentsOf: idWriter.bytes)
            body.append(contentsOf: payload)

            let timer = makeTimeout(id: id)
            lock.lock()
            timers[id] = timer
            lock.unlock()
            send(Self.frame(body))
        }
    }

    /// 发送 INIT（无 request-id）并等待 VERSION。
    func initialize() async throws -> UInt32 {
        let reply: SFTPReply = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SFTPReply, Error>) in
            let send: (@Sendable ([UInt8]) -> Void)?
            lock.lock()
            if versionPending != nil {
                lock.unlock()
                cont.resume(throwing: SFTPError.invalidPacket)
                return
            }
            versionPending = cont
            send = sendPacket
            lock.unlock()

            guard let send else {
                lock.lock()
                versionPending = nil
                lock.unlock()
                cont.resume(throwing: SFTPError.connectionClosed)
                return
            }

            var writer = SFTPWriter()
            writer.writeUInt32(3) // 客户端支持的最高版本
            let body: [UInt8] = [SFTPPacketType.initialize.rawValue] + writer.bytes
            send(Self.frame(body))
        }
        guard case .version(let version) = reply else {
            throw SFTPError.invalidPacket
        }
        return version
    }

    // MARK: 事件循环 / 管道回调

    /// 收到完整 SFTP 包（传输层线程）。
    func handleFrame(_ frame: [UInt8]) {
        guard let rawType = frame.first else { return }
        let type = SFTPPacketType(rawValue: rawType)
        var reader = SFTPReader(Array(frame.dropFirst()))

        if type == .version {
            guard let version = try? reader.readUInt32() else {
                failVersion(SFTPError.invalidPacket)
                return
            }
            lock.lock()
            let cont = versionPending
            versionPending = nil
            lock.unlock()
            cont?.resume(returning: .version(version))
            return
        }

        guard let id = try? reader.readUInt32() else { return }
        // 解析失败也要立即了结该请求：否则它会一直挂到 20s 看门狗，表现为「点了没反应」。
        do {
            let reply = try Self.parseReply(type: type, rawType: rawType, from: &reader)
            resolve(id: id, reply: reply)
        } catch {
            fail(id: id, error: error)
        }
    }

    /// 按应答类型解析 payload；任何字段读不动都抛出，交给调用方立即失败对应请求。
    private static func parseReply(type: SFTPPacketType?, rawType: UInt8,
                                   from reader: inout SFTPReader) throws -> SFTPReply {
        switch type {
        case .status:
            let code = try reader.readUInt32()
            let message = (try? reader.readString()) ?? ""
            return .status(code: code, message: message)
        case .handle:
            return .handle(try reader.readBytes())
        case .data:
            return .data(try reader.readBytes())
        case .name:
            let count = try reader.readUInt32()
            var items: [(name: String, longName: String, attrs: SFTPAttrs)] = []
            items.reserveCapacity(Int(min(count, 4096)))
            for _ in 0..<count {
                let name = try reader.readString()
                let longName = try reader.readString()
                let attrs = try SFTPAttrs.decode(from: &reader)
                items.append((name, longName, attrs))
            }
            return .name(items)
        case .attrs:
            return .attrs(try SFTPAttrs.decode(from: &reader))
        default:
            // 未知 / 暂不支持的应答类型：无法据 id 正常了结，让该请求立即失败而非空等超时。
            throw SFTPError.unsupportedReply(rawType)
        }
    }

    /// 通道 / 进程关闭（传输层线程）：失败所有挂起请求并回调。
    func channelDidClose() {
        lock.lock()
        sendPacket = nil
        let allPending = pending
        pending.removeAll()
        let allTimers = Array(timers.values)
        timers.removeAll()
        let versionCont = versionPending
        versionPending = nil
        let handler = onClosed
        lock.unlock()

        for timer in allTimers { timer.cancel() }
        for (_, cont) in allPending {
            cont.resume(throwing: SFTPError.connectionClosed)
        }
        versionCont?.resume(throwing: SFTPError.connectionClosed)
        handler?()
    }

    // MARK: 收尾

    /// 失败挂起请求并关停底层传输。
    func teardown() {
        lock.lock()
        sendPacket = nil
        let allPending = pending
        pending.removeAll()
        let allTimers = Array(timers.values)
        timers.removeAll()
        let versionCont = versionPending
        versionPending = nil
        let terminate = terminateTransport
        terminateTransport = nil
        onClosed = nil
        lock.unlock()

        for timer in allTimers { timer.cancel() }
        for (_, cont) in allPending {
            cont.resume(throwing: SFTPError.connectionClosed)
        }
        versionCont?.resume(throwing: SFTPError.connectionClosed)

        terminate?()
    }

    // MARK: 私有

    /// 给 body 加 4 字节大端长度前缀，得到线上整包。
    private static func frame(_ body: [UInt8]) -> [UInt8] {
        var writer = SFTPWriter()
        writer.writeUInt32(UInt32(body.count))
        return writer.bytes + body
    }

    private func resolve(id: UInt32, reply: SFTPReply) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        let timer = timers.removeValue(forKey: id)
        lock.unlock()
        timer?.cancel()
        cont?.resume(returning: reply)
    }

    /// 据 id 立即失败一个挂起请求（应答无法解析时用，避免干等到超时）。
    private func fail(id: UInt32, error: Error) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        let timer = timers.removeValue(forKey: id)
        lock.unlock()
        timer?.cancel()
        cont?.resume(throwing: error)
    }

    /// 立即失败等待中的 VERSION 握手。
    private func failVersion(_ error: Error) {
        lock.lock()
        let cont = versionPending
        versionPending = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }

    /// 创建请求超时看门狗：到点若请求仍未了结则摘除并抛错。应答到达时会被 cancel（见 resolve/fail）。
    private func makeTimeout(id: UInt32) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self else { return }
            self.lock.lock()
            let cont = self.pending.removeValue(forKey: id)
            self.timers.removeValue(forKey: id)
            self.lock.unlock()
            cont?.resume(throwing: SFTPError.timedOut)
        }
    }
}
