//
//  SSHConnectBanner.swift
//  devkit
//
//  M4：远程会话顶部的连接状态横幅、尚未选择会话的空状态入口、TOFU 信任询问弹窗（密码引擎）。
//

import SwiftUI

// MARK: - 连接横幅

struct SSHConnectBanner: View {
    @Bindable var tool: SSHTool
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let sub { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            trailingActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // 材质底由使用处的 `bannerCard()`（圆角 + 阴影悬浮卡片）提供，此处不再自铺背景。
    }

    /// 统一状态源：私钥引擎看 `remoteRunning`（外部 ssh 无细粒度状态），密码引擎看 `client.state`。
    private var state: SSHConnectionState {
        if tool.activeProfile?.authKind == .key {
            return tool.remoteRunning
                ? .connected(host: tool.activeProfile?.host ?? "")
                : .disconnected
        }
        return tool.client.state
    }

    private var statusDot: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        case .idle: return .secondary
        }
    }

    private var title: String {
        switch state {
        case .connected(let host): return host
        case .connecting: return "连接中…"
        case .failed: return "连接失败"
        case .disconnected: return "已断开"
        case .idle: return tool.activeProfile?.host ?? "未连接"
        }
    }

    private var sub: String? {
        switch state {
        case .failed(let m): return m
        default: return tool.activeProfile?.connectSummary
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        switch state {
        case .connected:
            Button("断开") { tool.disconnect() }
        case .failed, .disconnected:
            Button("重新连接") { tool.reconnect() }
            Button("换个目标") { openChooser() }
        case .connecting:
            ProgressView().controlSize(.small)
        case .idle:
            Button("换个目标") { openChooser() }
        }
    }

    /// 结束当前会话并重新唤起本标签的连接选择弹窗。
    private func openChooser() {
        tool.clearSession()
        if let id = appState.tabID(for: tool) { appState.sshChooserTabID = id }
    }
}

// MARK: - 空状态入口

/// 尚未选择会话类型时的占位入口（也用于“换个目标”返回后）。
struct SSHEmptyPrompt: View {
    @Bindable var tool: SSHTool
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("开始一个终端会话").font(.title3.weight(.semibold))

            VStack(spacing: 10) {
                actionCard(icon: "house", title: "本地终端", subtitle: "打开本机 shell（默认进入个人目录）") {
                    tool.startLocal()
                }
                actionCard(icon: "network", title: "新建 / 选择 SSH 连接", subtitle: "从弹窗选择已有或新建") {
                    openChooser()
                }
            }
            .frame(width: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 材质底由外层终端卡片（SSHToolView.terminalSurface）提供，此处不再自铺背景。
    }

    private func openChooser() {
        if let id = appState.tabID(for: tool) { appState.sshChooserTabID = id }
    }

    private func actionCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 24).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - TOFU 信任询问（密码引擎）

struct SSHTrustPromptView: View {
    let host: String
    let port: Int
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("信任此主机？", systemImage: "lock.shield")
                .font(.headline)
            Text("\(host):\(port)")
                .font(.body.monospaced())
            Text("首次连接该主机，无法验证其身份。确认指纹无误后再信任。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { onDecide(false) }
                    .keyboardShortcut(.cancelAction)
                Button("信任并连接") { onDecide(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
