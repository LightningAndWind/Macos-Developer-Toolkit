//
//  AppShellView.swift
//  devkit
//
//  App 主界面：左侧竖向标签栏（固定四档宽度：超窄 / 标准 / 加宽一半 / 加宽一倍）
//  + 纯视觉分割线 + 右侧内容区（工具视图 / Launcher）。
//

import SwiftUI

struct AppShellView: View {
    @Environment(AppState.self) private var appState
    /// 观察明暗外观：深色下给底层材质叠一层半透黑 scrim 压暗（材质会把桌面亮度透上来，不压则偏浅灰）。
    @Environment(\.colorScheme) private var colorScheme

    /// 展开态宽度档位（持久化）。与标签栏里的档位按钮共用同一 @AppStorage 键。
    @AppStorage(AppPreferences.sidebarWidthModeKey)
    private var widthMode: Theme.SidebarWidthMode = .standard

    /// 侧栏是否切换为超窄模式（标准档一半宽度，样式不变，持久化）。
    @AppStorage(AppPreferences.sidebarCollapsedKey)
    private var sidebarCollapsed = false

    /// 四档中当前生效的宽度。只在点击档位 / 超窄按钮时变化，无逐帧状态。
    private var sidebarWidth: CGFloat {
        sidebarCollapsed ? Theme.Metrics.sidebarUltraNarrowWidth : widthMode.width
    }

    /// 侧栏视觉宽度：宽度过渡只作用在侧栏本体上。
    /// 若让整个 HStack 逐帧插值，所有常驻工具视图（终端等）会在动画期间每帧 resize，
    /// 一帧的布局成本被放大几十倍，表现为一次切换卡上数秒。
    @State private var visualSidebarWidth: CGFloat?
    /// 收起（宽度变小）时侧栏会盖住已按新档位落位的内容，垫不透明底板避免内容透过材质显影。
    @State private var isShrinkingSidebar = false

    var body: some View {
        @Bindable var appState = appState
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                // 占位：内容区按最终档位立即落位，动画期间尺寸不再变化，重内容只 resize 一次。
                Color.clear
                    .frame(width: sidebarWidth)
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 常驻标签即使 opacity(0) 仍参与布局：某个工具视图若有负向偏移，
                    // 其内容会越过侧栏左边界、露在窗口最左缘（超窄模式尤其明显）。
                    // 统一裁到内容区边界，杜绝任何跨栏溢出。
                    .clipped()
            }
            // 内容区宽度随档位一次性切换，不参与过渡（过渡只由下面的侧栏视觉层承担）。
            .animation(nil, value: sidebarWidth)
            // 视觉侧栏：宽度过渡的唯一载体，覆盖在占位区与内容之上。
            SidebarColumn(width: visualSidebarWidth ?? sidebarWidth)
                .background(isShrinkingSidebar ? Color(nsColor: .windowBackgroundColor) : Color.clear)
                // 侧栏宽度已固定为档位，分割线退化为纯视觉细线（不可拖拽）。
                // 可拖拽的 SidebarResizeDivider 仍供 Git 变更列表的列表/预览分栏使用。
                .overlay(alignment: .trailing) { SidebarSeparator() }
        }
        .onAppear { visualSidebarWidth = sidebarWidth }
        // 宽度档位来自 @AppStorage：跨视图同步发生在点击事务之外，包在 withAnimation 里也不一定生效。
        // 这里在宽度真正变化时显式驱动侧栏视觉层的过渡。
        .onChange(of: sidebarWidth) { oldWidth, newWidth in
            isShrinkingSidebar = newWidth < oldWidth
            withAnimation(Theme.Motion.sidebarResize, completionCriteria: .logicallyComplete) {
                visualSidebarWidth = newWidth
            } completion: {
                isShrinkingSidebar = false
            }
        }
        // 让侧栏顶到窗口最上沿，为左上角三色按钮留出空间。
        .ignoresSafeArea(.container, edges: .top)
        .background {
            // 底层毛玻璃材质；深色模式在其上叠半透黑，使整体更偏黑（内容区 / 终端 / Launcher 首页随之一起变深，彼此无色差）。
            ZStack {
                VisualEffectBackground()
                if colorScheme == .dark {
                    Color.black.opacity(0.45)
                }
            }
            .ignoresSafeArea()
        }
        // 窗口最小尺寸：为 Git 差异/冲突预览等双栏编辑场景留出足够空间（列表 150-420 + 预览区）。1pt 误差无感知，取整数值。
        .frame(minWidth: 1000, minHeight: 640)
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
        // 新建 Git 标签时的“登记 / 克隆 / 打开已保存”选择框。
        .sheet(
            isPresented: Binding(
                get: { appState.gitChooserTabID != nil },
                set: { if !$0 { appState.gitChooserTabID = nil } }
            )
        ) {
            if let tabID = appState.gitChooserTabID {
                GitStartupChooser(tabID: tabID) { appState.gitChooserTabID = nil }
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

/// 侧栏列：固定宽度档位的唯一落点。
///
/// `alignment: .leading` + `.clipped()` 很关键：超窄模式下内容若按展开态宽度布局，
/// 默认居中的 frame 会让内容向左右各溢出一半，左边那半就会露到窗口最左缘
/// （表现为截图里的文字残影 / 越界竖条）。左对齐并裁剪后所有子视图严格留在侧栏内。
private struct SidebarColumn: View {
    let width: CGFloat

    var body: some View {
        TabBarView()
            .frame(width: width, alignment: .leading)
            .clipped()
    }
}

/// 侧栏与内容区之间的 1pt 视觉分割线（不可拖拽，宽度由档位按钮控制）。
private struct SidebarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.splitter)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
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
