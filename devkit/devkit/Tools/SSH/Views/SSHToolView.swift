//
//  SSHToolView.swift
//  devkit
//
//  M4：SSH 工具根视图 —— 只呈现终端区（本地 / 远程 / 未选择）。
//  连接的「新建 / 选择已有（含多级文件夹）」走 HTTP 式弹窗（SSHStartupChooser），不再内嵌侧栏。
//

import SwiftUI

struct SSHToolView: View {
    @Bindable var tool: SSHTool
    @Environment(AppState.self) private var appState

    var body: some View {
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .onChange(of: tool.client.state) { _, _ in appState.scheduleSessionSave() }
            .sheet(item: $tool.pendingTrust) { request in
                SSHTrustPromptView(host: request.host, port: request.port) { trusted in
                    tool.resolveTrust(trusted: trusted)
                }
            }
    }

    @ViewBuilder
    private var detail: some View {
        switch tool.sessionKind {
        case .local:
            LocalTerminalContainer()
        case .remote:
            remoteDetail
        case nil:
            SSHEmptyPrompt(tool: tool)
        }
    }

    private var remoteDetail: some View {
        VStack(spacing: 0) {
            SSHConnectBanner(tool: tool)
            Divider()
            if case .connected = tool.client.state {
                SSHTerminalContainer(client: tool.client)
            } else {
                SSHTerminalPlaceholder(state: tool.client.state)
            }
        }
    }
}

/// 远程未连接时终端区域的占位（连接中 / 失败 / 断开）。
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
        .background(Theme.Palette.terminalBackground)
        .foregroundStyle(.primary)
    }
}
