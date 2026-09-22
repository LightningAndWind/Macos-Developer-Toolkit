//
//  SSHTool.swift
//  devkit
//
//  M4：SSH 终端工具（视图模型）。一个标签 = 一个会话：本地 shell 或远程 SSH。
//  远程经 SSHClient(NIOSSH) 连接；连接配置（profile）按 HTTP 式多级文件夹集合管理，存 SQLite。
//  新标签进入「选择器」：本地 / 新建 SSH / 选择已有 SSH。
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

    /// 远程会话传输对象。
    @ObservationIgnored let client = SSHClient()

    /// 待用户确认信任的新主机（TOFU）。
    var pendingTrust: TrustRequest?

    /// 连接状态镜像（供 banner 直接观察，避免视图深入 client）。
    var connectionState: SSHConnectionState { client.state }

    struct TrustRequest: Identifiable {
        let id = UUID()
        let host: String
        let port: Int
        let resume: @MainActor (Bool) -> Void
    }

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
    }

    /// 选择/新建远程：设为活动配置并以默认尺寸发起连接（终端就绪后会自动 resize 校正）。
    func connect(to profile: SSHProfile) {
        sessionKind = .remote
        activeProfile = profile
        Task { await client.connect(profile: profile, cols: 80, rows: 24) }
    }

    func disconnect() {
        client.disconnect()
    }

    /// 断开后重连当前配置。
    func reconnect() {
        guard let profile = activeProfile else { return }
        Task { await client.connect(profile: profile, cols: 80, rows: 24) }
    }

    /// 结束当前会话（回到未选择态），供“换个目标”前重置标签内容。
    func clearSession() {
        client.disconnect()
        sessionKind = nil
        activeProfile = nil
    }

    /// 标签关闭：显式结束会话，并放行仍在等待「信任询问」的连接任务。
    ///
    /// 必须做，否则会构成引用环：`requestTrust` 把 continuation 存进 `pendingTrust`，
    /// 而发起连接的 `Task { await client.connect(…) }` 又强持有本工具 ——
    /// 用户在 TOFU 提示上直接关标签时没有任何代码调用 `resolveTrust`，两者便永远互相持有，
    /// SSHClient（连带其事件循环线程与 socket）一并泄漏。
    func teardownOnTabClose() {
        // 先让挂起的连接任务退出，再释放连接资源。
        resolveTrust(trusted: false)
        clearSession()
    }

    // MARK: - TOFU 信任询问

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

    /// 从快照恢复：本地直接回到本地终端；远程仅回填配置并置为「已断开」，
    /// 由横幅展示「重新连接」按钮交给用户点击（不自动联网，避免 surprise）。
    @MainActor func restoreSessionState(_ data: Data) {
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
        switch state.sessionKind {
        case .local:
            sessionKind = .local
        case .remote:
            if let id = state.profileID, let profile = SSHProfileStore.load(id: id) {
                sessionKind = .remote
                activeProfile = profile
                // 回填成功：进入「已断开」，横幅据此呈现「重新连接」。
                client.markRestoredDisconnected()
            } else {
                // 配置已被删除：保持未连接的空目标态，用户走「换个目标」。
                sessionKind = .remote
            }
        case nil:
            break
        }
    }
}
