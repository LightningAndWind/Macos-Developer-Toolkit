//
//  SSHToolView.swift
//  devkit
//
//  M4：SSH 工具根视图 —— 呈现终端区（本地 / 远程 / 未选择）。
//  远程按认证方式分引擎：私钥 → RemoteSSHContainer（系统 ssh）；密码 → SSHTerminalContainer（NIOSSH 自动登录）。
//  连接的「新建 / 选择已有」走 HTTP 式弹窗（SSHStartupChooser）。
//

import SwiftUI

struct SSHToolView: View {
    @Bindable var tool: SSHTool
    @Environment(AppState.self) private var appState
    /// 驱动面板 tint 随明暗变化：与终端 ANSI 色板同一外观基准，保证内边距环与终端区同色。
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 外部边距：终端卡片与窗口四边都留白。
            .padding(Theme.Metrics.terminalContentInset)
            .onChange(of: tool.remoteRunning) { _, _ in appState.scheduleSessionSave() }
            .onChange(of: tool.client.state) { _, _ in appState.scheduleSessionSave() }
            // 密码引擎首次连新主机的 TOFU 信任询问。
            .sheet(item: $tool.pendingTrust) { request in
                SSHTrustPromptView(host: request.host, port: request.port) { trusted in
                    tool.resolveTrust(trusted: trusted)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch tool.sessionKind {
        case .local:
            terminalSurface(LocalTerminalContainer())
        case .remote:
            remoteContent
        case nil:
            terminalSurface(SSHEmptyPrompt(tool: tool))
        }
    }

    /// 远程：顶部悬浮连接横幅 + 下方终端区（按认证方式选引擎）。
    private var remoteContent: some View {
        VStack(spacing: Theme.Metrics.bannerTerminalGap) {
            SSHConnectBanner(tool: tool)
                .bannerCard()
            remoteTerminalArea
        }
    }

    @ViewBuilder
    private var remoteTerminalArea: some View {
        if tool.activeProfile?.authKind == .key {
            // 私钥：外部 ssh 子进程。`.id(launchID)` 让重连换 id → 销毁旧容器（terminate 杀旧 ssh）并新建。
            if tool.remoteRunning, let profile = tool.activeProfile {
                terminalSurface(RemoteSSHContainer(profile: profile))
                    .id(tool.remoteLaunchID)
            } else {
                terminalSurface(remoteDisconnectedView)
            }
        } else {
            // 密码：进程内 NIOSSH，已连接显示终端，否则显示连接中/失败/断开占位。
            if case .connected = tool.client.state {
                terminalSurface(SSHTerminalContainer(client: tool.client))
            } else {
                terminalSurface(SSHTerminalPlaceholder(state: tool.client.state))
            }
        }
    }

    /// 私钥会话未连接 / 已断开时的终端区占位。
    private var remoteDisconnectedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(tool.activeProfile == nil ? "未选择连接" : "会话已断开")
                .foregroundStyle(.secondary)
            if tool.activeProfile != nil {
                Button("重新连接") { tool.reconnect() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.primary)
    }

    /// 把终端/占位区包成一张圆角毛玻璃卡片（内边距 + 面板 tint + 裁圆角）。
    private func terminalSurface<Content: View>(_ content: Content) -> some View {
        content
            // 内边距：终端文字距面板内边留白，不贴边。
            .padding(Theme.Metrics.terminalInnerPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 终端面板：毛玻璃底 + 随明暗的窗口底色 tint（终端视图自身透明，露出此面板）。
            .background {
                ZStack {
                    terminalPanel.fill(.ultraThinMaterial)
                    terminalPanel.fill(Color(nsColor: .windowBackgroundColor)
                        .opacity(colorScheme == .dark ? 0 : 0.2))
                }
            }
            .clipShape(terminalPanel)
    }

    /// 终端面板形状：四周圆角，半径近似窗口圆角。
    private var terminalPanel: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Metrics.terminalCornerRadius, style: .continuous)
    }
}

/// 密码引擎未连接时终端区域的占位（连接中 / 失败 / 断开）。
private struct SSHTerminalPlaceholder: View {
    let state: SSHConnectionState

    var body: some View {
        VStack(spacing: 10) {
            switch state {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("正在连接…").foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            case .disconnected:
                Image(systemName: "wifi.slash")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("会话已结束").foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.primary)
    }
}

private extension View {
    /// 连接横幅的悬浮卡片外观：圆角毛玻璃底 + 细描边 + 轻阴影，浮于终端之上。
    func bannerCard() -> some View {
        self
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.bannerCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.bannerCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .shadow(color: Theme.Palette.floatingShadow, radius: 6, y: 2)
    }
}
