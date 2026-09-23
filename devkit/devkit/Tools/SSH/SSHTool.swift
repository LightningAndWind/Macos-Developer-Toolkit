//
//  SSHTool.swift
//  devkit
//
//  M4：SSH 终端工具（视图模型）。一个标签 = 一个会话：本地 shell 或远程 SSH。
//  远程按认证方式分两条引擎：
//   - 密码认证 → 进程内 NIOSSH（SSHClient），自动登录、不在终端弹密码提示；主机指纹走应用内 TOFU。
//   - 私钥认证 → 系统 `/usr/bin/ssh` 子进程（RemoteSSHContainer），原生支持 RSA（如 boot.pem）、
//     rsa-sha2、口令与 known_hosts；主机确认由 ssh 在终端内交互完成。
//  连接配置（profile）按 HTTP 式多级文件夹集合管理，存 SQLite。新标签进入「选择器」。
//

import SwiftUI

@Observable
final class SSHTool: DevkitTool {
    static let descriptor = ToolDescriptor(
        id: "tool.ssh",
        title: "SSH 终端",
        symbolName: "terminal",
        category: .terminal,
        subtitle: "本地终端与 SSH 会话，连接配置按文件夹归类管理。",
        allowsMultipleInstances: true,
        supportsWindowDetach: true
    )

    var descriptor: ToolDescriptor { Self.descriptor }

    // MARK: - 会话状态

    /// nil = 尚未选择会话类型（新标签未通过选择器）。
    private(set) var sessionKind: SSHSessionKind?
    /// 远程会话当前使用的连接配置。
    private(set) var activeProfile: SSHProfile?

    // —— 密码认证引擎：进程内 NIOSSH ——

    /// 密码会话传输对象（其 `state` 由 SSHClient 自身 @Observable 追踪，视图直接观察）。
    @ObservationIgnored let client = SSHClient()

    /// 待用户确认信任的新主机（TOFU，仅密码引擎用到）。
    var pendingTrust: TrustRequest?

    struct TrustRequest: Identifiable {
        let id = UUID()
        let host: String
        let port: Int
        let resume: @MainActor (Bool) -> Void
    }

    // —— 私钥认证引擎：外部 ssh 子进程 ——

    /// 远程 ssh 进程会话是否运行中（true 展示终端；false 展示「已断开」占位，由用户点「重新连接」）。
    private(set) var remoteRunning = false

    /// 远程 ssh 会话身份：每次（重）连接换一个 UUID，视图据此 `.id()` 重建容器 → 重启 ssh 进程。
    private(set) var remoteLaunchID = UUID()

    /// 当前远程会话是否走外部 ssh（私钥认证）。
    private var usesExternalSSH: Bool { activeProfile?.authKind == .key }

    // MARK: - DevkitTool

    var dynamicTabTitle: String? {
        switch sessionKind {
        case .local: return "本地终端"
        case .remote: return activeProfile?.host
        case nil: return nil
        }
    }

    /// 终端会话不产生“未保存”概念：不显示脏标记 `*`。
    var hasUnsavedContent: Bool { false }

    init() {
        client.trustHandler = { [weak self] host, port in
            guard let self else { return false }
            return await self.requestTrust(host: host, port: port)
        }
    }

    @MainActor func makeView() -> AnyView {
        AnyView(SSHToolView(tool: self))
    }

    // MARK: - 会话动作

    /// 选择「本地」：进入本地 shell。
    func startLocal() {
        sessionKind = .local
        activeProfile = nil
        remoteRunning = false
        client.disconnect()
    }

    /// 选择/新建远程：按认证方式选引擎并发起连接。
    func connect(to profile: SSHProfile) {
        sessionKind = .remote
        activeProfile = profile
        if profile.authKind == .key {
            remoteLaunchID = UUID()
            remoteRunning = true
        } else {
            Task { await client.connect(profile: profile, cols: 80, rows: 24) }
        }
    }

    /// 断开当前远程会话。
    func disconnect() {
        if usesExternalSSH { remoteRunning = false } else { client.disconnect() }
    }

    /// 断开后重连当前配置。
    func reconnect() {
        guard let profile = activeProfile else { return }
        if profile.authKind == .key {
            remoteLaunchID = UUID()
            remoteRunning = true
        } else {
            Task { await client.connect(profile: profile, cols: 80, rows: 24) }
        }
    }

    /// 结束当前会话（回到未选择态），供“换个目标”前重置标签内容。
    func clearSession() {
        remoteRunning = false
        client.disconnect()
        sessionKind = nil
        activeProfile = nil
    }

    /// 标签关闭：放行挂起的信任询问并结束会话（外部 ssh 容器随之 dismantle → terminate 杀进程）。
    func teardownOnTabClose() {
        resolveTrust(trusted: false)
        clearSession()
    }

    // MARK: - TOFU 信任询问（密码引擎）

    @MainActor private func requestTrust(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingTrust = TrustRequest(host: host, port: port) { decision in
                cont.resume(returning: decision)
            }
        }
    }

    func resolveTrust(trusted: Bool) {
        pendingTrust?.resume(trusted)
        pendingTrust = nil
    }

    // MARK: - 会话持久化

    private struct SessionState: Codable {
        var sessionKind: SSHSessionKind?
        var profileID: UUID?
    }

    @MainActor func sessionStateData() -> Data? {
        guard let sessionKind else { return nil }
        let state = SessionState(sessionKind: sessionKind, profileID: activeProfile?.id)
        return try? JSONEncoder().encode(state)
    }

    /// 从快照恢复：本地直接回本地终端；远程仅回填配置并置为「已断开」，
    /// 由横幅展示「重新连接」交给用户点击（不自动联网，避免 surprise）。
    @MainActor func restoreSessionState(_ data: Data) {
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
        switch state.sessionKind {
        case .local:
            sessionKind = .local
        case .remote:
            if let id = state.profileID, let profile = SSHProfileStore.load(id: id) {
                sessionKind = .remote
                activeProfile = profile
                // 回填成功：保持「已断开」，横幅据此呈现「重新连接」，不自动连接。
                if profile.authKind == .key { remoteRunning = false } else { client.markRestoredDisconnected() }
            } else {
                // 配置已被删除：保持未连接的空目标态，用户走「换个目标」。
                sessionKind = .remote
            }
        case nil:
            break
        }
    }
}
