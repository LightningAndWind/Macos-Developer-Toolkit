//
//  AppShellView.swift
//  devkit
//
//  App 主界面：左侧竖向标签栏（侧栏）+ 右侧内容区（工具视图 / Launcher）。
//

import SwiftUI

struct AppShellView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 0) {
            TabBarView()
                .frame(width: Theme.Metrics.sidebarWidth)
            Divider()
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
    }

    /// 内容区：直接切换，无转场动画（避免切 tab 时的违和感）。
    @ViewBuilder
    private var contentArea: some View {
        if appState.tabManager.isLauncherPresented || appState.tabManager.selectedTab == nil {
            LauncherView()
        } else if let tab = appState.tabManager.selectedTab,
                  let tool = tab.toolInstance {
            tool.makeView()
                .id(tab.id) // 切 tab 时强制重建视图，隔离工具间状态
        } else {
            ContentUnavailableView("未选择标签", systemImage: "square.dashed")
        }
    }
}

#Preview {
    AppShellView()
        .environment(AppState.shared)
}
