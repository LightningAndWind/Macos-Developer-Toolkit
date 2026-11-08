//
//  SSHToolView.swift
//  devkit
//
//  M4：SSH 工具根视图 —— 呈现终端区（本地 / 远程 / 未选择）。
//  远程按认证方式分引擎：私钥 → RemoteSSHContainer（系统 ssh）；密码 → SSHTerminalContainer（NIOSSH 自动登录）。
//  连接的「新建 / 选择已有」走 HTTP 式弹窗（SSHStartupChooser）。
//  右缘竖向工具条（SSHSideStripView，类 IDE stripe）承载记事本等侧边功能开关；
//  记事本面板悬浮叠在终端右缘之上（不挤占终端内容区）；工具条常驻布局列不遮挡内容。
//

import SwiftUI

struct SSHToolView: View {
    @Bindable var tool: SSHTool
    @Environment(AppState.self) private var appState
    /// 终端自绘滚动指示条的共享模型（由各终端容器的 NSScroller 监听器更新）。
    @State private var terminalScroll = TerminalScrollModel()
    /// 右侧记事本面板展开态（开关在右缘竖向工具条上）。
    @State private var showNotepad = false
    /// 记事本编辑器放大态（面板级：放大时面板整体加宽，状态在此驱动宽度）。
    @State private var notepadEnlarged = false

    /// 面板完全滑出窗口右缘所需的最小位移（随放大态变化）：
    /// 面板宽（常规 256 / 放大 420）+ 右侧留白（工具条 34 + 间距 8）+ 内容外边距 10 + 阴影余量。
    private var notepadExitOffset: CGFloat {
        let panelWidth = notepadEnlarged
            ? Theme.Metrics.notepadPanelExpandedWidth
            : Theme.Metrics.notepadPanelWidth
        return panelWidth + Theme.Metrics.sideStripWidth
            + Theme.Metrics.terminalSideGap + Theme.Metrics.terminalContentInset + 16
    }

    var body: some View {
        // 终端区与右缘工具条照常参与布局（工具条仅 34pt 常驻右缘，不遮挡内容）；
        // 只有记事本面板是悬浮层：展开时覆盖在终端右缘之上，不挤压终端内容区。
        // 面板用 trailing 内边距让出工具条位置——悬浮但盖住开关就无法收起了。
        //
        // 面板必须常驻层级、只用 offset 控制出入画：transition 的移除会重挂视图层级，
        // 盖在 NSView 终端（平台视图）上时会出现「收回瞬间沉到终端后面再滑走」的层级跳变；
        // 常驻视图 z 序稳定，两个方向都一致地滑于终端前方（无淡入淡出，滑动手感对称）。
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: Theme.Metrics.terminalSideGap) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                sideStrip
            }
            TerminalNotePadPanel(inputHub: tool.terminalInput,
                                 currentProfileID: tool.activeProfile?.id,
                                 editorEnlarged: notepadEnlarged,
                                 onToggleEditorEnlarged: {
                                     withAnimation(Theme.Motion.content) { notepadEnlarged.toggle() }
                                 })
                // 面板自定义 Equatable：本视图每轮 body 都会新建上面的回调闭包，
                // 不显式忽略会让终端侧任何重绘都传染成面板 body 重算。
                .equatable()
                .frame(width: notepadEnlarged
                       ? Theme.Metrics.notepadPanelExpandedWidth
                       : Theme.Metrics.notepadPanelWidth)
                // 分类下拉是自绘弹层，要溢出面板边界；只让背景板裁圆角，内容不裁。
                .terminalCardSurface(clipsContent: false)
                .padding(.trailing, Theme.Metrics.sideStripWidth + Theme.Metrics.terminalSideGap)
                .offset(x: showNotepad ? 0 : notepadExitOffset)
                .allowsHitTesting(showNotepad)
                .accessibilityHidden(!showNotepad)
        }
        // 这里刻意不挂 `.animation(_:value:)`：它会把整个 ZStack 子树（含 AppKit
        // 终端容器与常驻记事本面板）纳入隐式动画作用域。开关与放大两处已经显式
        // `withAnimation`，事务只覆盖真正变化的那一次，作用域更小也更可预测。
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

    /// 右缘竖向工具条：记事本开关在此；后续新增侧边功能往 items 里加一项即可。
    private var sideStrip: some View {
        SSHSideStripView(items: [
            SSHSideStripItem(id: "notepad",
                             symbol: "note.text",
                             help: "记事本",
                             isActive: showNotepad) {
                withAnimation(Theme.Motion.content) { showNotepad.toggle() }
            }
        ])
    }

    @ViewBuilder
    private var content: some View {
        switch tool.sessionKind {
        case .local:
            // `.id(launchID)`：从另一条本地记录打开 / 重开时换 id → 以新目录重建 shell。
            terminalSurface(LocalTerminalContainer(workingDirectory: tool.localWorkingDirectory,
                                                   scrollModel: terminalScroll,
                                                   inputHub: tool.terminalInput)
                .terminalScrollIndicator(terminalScroll))
                .id(tool.localLaunchID)
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
                terminalSurface(RemoteSSHContainer(profile: profile,
                                                   scrollModel: terminalScroll,
                                                   inputHub: tool.terminalInput)
                    .terminalScrollIndicator(terminalScroll))
                    .id(tool.remoteLaunchID)
            } else {
                terminalSurface(remoteDisconnectedView)
            }
        } else {
            // 密码：进程内 NIOSSH，已连接显示终端，否则显示连接中/失败/断开占位。
            if case .connected = tool.client.state {
                terminalSurface(SSHTerminalContainer(client: tool.client,
                                                     scrollModel: terminalScroll,
                                                     inputHub: tool.terminalInput)
                    .terminalScrollIndicator(terminalScroll))
            } else {
                terminalSurface(SSHTerminalPlaceholder(state: tool.client.state,
                                                       attempt: tool.client.connectAttempt))
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
            .terminalCardSurface()
    }
}

/// 密码引擎未连接时终端区域的占位（连接中 / 失败 / 断开）。`attempt` > 1 表示瞬时不可达自动重试中。
private struct SSHTerminalPlaceholder: View {
    let state: SSHConnectionState
    var attempt: Int = 0

    var body: some View {
        VStack(spacing: 10) {
            switch state {
            case .connecting:
                ProgressView().controlSize(.small)
                Text(attempt > 1 ? String(format: L("网络暂不可达，自动重试中（第 %@ 次）…"), String(attempt)) : "正在连接…")
                    .foregroundStyle(.secondary)
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
