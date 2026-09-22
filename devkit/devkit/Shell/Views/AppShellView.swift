//
//  AppShellView.swift
//  devkit
//
//  App 主界面：左侧竖向标签栏（侧栏）+ 可拖拽调整宽度的分割线 + 右侧内容区（工具视图 / Launcher）。
//

import SwiftUI

struct AppShellView: View {
    @Environment(AppState.self) private var appState

    /// 侧栏宽度：写入 UserDefaults，拖拽调整后重启仍保持。
    @AppStorage(AppPreferences.sidebarWidthKey)
    private var storedSidebarWidth: Double = Theme.Metrics.sidebarWidth

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 0) {
            TabBarView()
                .frame(width: sidebarWidth)
            SidebarResizeDivider(width: sidebarWidthBinding,
                                range: Theme.Metrics.sidebarMinWidth...Theme.Metrics.sidebarMaxWidth,
                                defaultWidth: Theme.Metrics.sidebarWidth)
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 让侧栏顶到窗口最上沿，为左上角三色按钮留出空间。
        .ignoresSafeArea(.container, edges: .top)
        .background(VisualEffectBackground().ignoresSafeArea())
        .frame(minWidth: 900, minHeight: 560)
        .unifiedTitleBar()
        .confirmationDialog(
            "该标签有未保存内容，确定关闭？",
            isPresented: Binding(
                get: { appState.pendingCloseTabID != nil },
                set: { if !$0 { appState.pendingCloseTabID = nil } }
            ),
            titleVisibility: .visible,
            presenting: appState.pendingCloseTabID
        ) { tabID in
            Button("关闭", role: .destructive) {
                appState.closeTab(tabID)
                appState.pendingCloseTabID = nil
            }
            Button("取消", role: .cancel) {
                appState.pendingCloseTabID = nil
            }
        }
        // 新建 HTTP 标签时的“新建 / 打开已保存”选择框。
        .sheet(
            isPresented: Binding(
                get: { appState.httpChooserTabID != nil },
                set: { if !$0 { appState.httpChooserTabID = nil } }
            )
        ) {
            if let tabID = appState.httpChooserTabID {
                HTTPStartupChooser(tabID: tabID) { appState.httpChooserTabID = nil }
            }
        }
        // 新建 SSH 标签时的“本地 / 新建 / 选择已有”选择框。
        .sheet(
            isPresented: Binding(
                get: { appState.sshChooserTabID != nil },
                set: { if !$0 { appState.sshChooserTabID = nil } }
            )
        ) {
            if let tabID = appState.sshChooserTabID {
                SSHStartupChooser(tabID: tabID) { appState.sshChooserTabID = nil }
            }
        }
        // 首次 ⌘S 的“保存位置”对话框。
        .sheet(
            isPresented: Binding(
                get: { appState.pendingSaveTabID != nil },
                set: { if !$0 { appState.pendingSaveTabID = nil } }
            )
        ) {
            if let tabID = appState.pendingSaveTabID {
                RequestSaveDialog(tabID: tabID) { appState.pendingSaveTabID = nil }
            }
        }
        // 设置面板：侧栏左下角设置按钮 / 菜单「设置…」触发。
        .sheet(
            isPresented: Binding(
                get: { appState.isSettingsPresented },
                set: { appState.isSettingsPresented = $0 }
            )
        ) {
            SettingsView()
        }
    }

    /// 限幅后的侧栏宽度：容错历史存量值与设计令牌调整导致的越界。
    private var sidebarWidth: CGFloat {
        let lower = Double(Theme.Metrics.sidebarMinWidth)
        let upper = Double(Theme.Metrics.sidebarMaxWidth)
        return CGFloat(min(max(storedSidebarWidth, lower), upper))
    }

    /// 提供给分割线拖拽的绑定：读回限幅值，写入原始值。
    private var sidebarWidthBinding: Binding<CGFloat> {
        Binding(get: { sidebarWidth }, set: { storedSidebarWidth = Double($0) })
    }

    /// 内容区：已打开的标签常驻，切换仅改透明度/命中测试，不销毁重建视图树。
    /// 这样避开每次切回 HTTP 标签都要重建较重的表单 + 重跑 `.task`，消除切换延迟；
    /// 关闭标签后其从 tabs 移除，对应视图随之销毁释放。
    /// 切换仍无转场动画（避免违和感）。
    @ViewBuilder
    private var contentArea: some View {
        ZStack {
            ForEach(appState.tabManager.tabs) { tab in
                // 每标签包成 Equatable 子视图：切换选中时只有可见性真正变化的标签会重算 body，
                // 其余常驻标签被 SwiftUI 判为相等直接跳过，避免整排 HTTP 表单一起重渲染的卡顿。
                ResidentToolTab(tab: tab, isVisible: isTabShown(tab.id))
                    .equatable()
            }
            // Launcher 覆盖在标签之上；此时标签仅隐藏不销毁，返选择不重建。
            if appState.tabManager.isLauncherPresented || appState.tabManager.selectedTab == nil {
                LauncherView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 某标签是否为当前可见层（非 Launcher 且处于选中）。
    private func isTabShown(_ id: UUID) -> Bool {
        !appState.tabManager.isLauncherPresented
            && appState.tabManager.selectedTabID == id
    }
}

/// 常驻的单标签内容视图。`Equatable`：当标签身份与可见性均未变时，SwiftUI 跳过重算 body，
/// 让切换只重绘“进/出”的两个标签，而不牵动其余已打开标签（可能很重的）视图树。
private struct ResidentToolTab: View, Equatable {
    let tab: Tab
    let isVisible: Bool

    var body: some View {
        Group {
            if let tool = tab.toolInstance {
                tool.makeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        // 把可见性透传给工具：不可见的常驻标签需真正隐藏其内部 NSTextView，
        // 否则其 I 型光标热区与插入点会叠加到当前标签之上。
        .environment(\.activeToolTab, isVisible)
    }
}

#Preview {
    AppShellView()
        .environment(AppState.shared)
}

// MARK: - 标签可见性环境值

private struct ActiveToolTabKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 当前工具标签是否为可见层。常驻但不可见的标签据此隐藏其重量级 NSTextView。
    var activeToolTab: Bool {
        get { self[ActiveToolTabKey.self] }
        set { self[ActiveToolTabKey.self] = newValue }
    }
}
