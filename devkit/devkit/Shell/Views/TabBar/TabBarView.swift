//
//  TabBarView.swift
//  devkit
//
//  左侧竖向标签栏（侧栏）：顶部为三色按钮预留空间，
//  下方竖向列表渲染 layoutRows（分组头 + 标签），末尾追加与标签等大的“+”整行按钮。超出高度显示自绘滚动指示条，支持滚轮。
//  最底部为固定操作条（设置按钮），位于滚动区之外，不随标签列表滚动。
//  侧栏宽度改为固定四档（超窄 / 标准 / 加宽一半 / 加宽一倍），由顶部按钮切换：
//  行矩形跟随宽度伸缩，标题在窄到装不下时于右缘渐隐（见 FadingTitleText）。
//

import SwiftUI

struct TabBarView: View {
    @Environment(AppState.self) private var appState

    private var tabManager: TabManager { appState.tabManager }

    /// 侧栏是否切换为超窄模式（与 AppShellView 共用同一持久化键，@AppStorage 自动同步）。
    @AppStorage(AppPreferences.sidebarCollapsedKey) private var sidebarCollapsed = false

    /// 展开态宽度档位（与 AppShellView 共用同一持久化键，@AppStorage 自动同步）。
    @AppStorage(AppPreferences.sidebarWidthModeKey)
    private var widthMode: Theme.SidebarWidthMode = .standard

    /// 拖拽协调器：跨行共享的拖拽瞬时状态。
    @State private var drag = TabDragCoordinator()
    /// 各行在侧栏坐标空间中的实时位置（拖拽开始前用于建立布局快照；只存 origin，见 TabRowFrames）。
    @State private var liveRowFrames: [UUID: CGPoint] = [:]
    /// 收起/展开按钮的悬停态。
    @State private var isCollapseHovering = false

    var body: some View {
        VStack(spacing: 0) {
            header
            collapseRow
            tabList
            SidebarFooterBar()
        }
        .frame(maxHeight: .infinity)
        .background(TabBarBackground())
        // 侧栏根容器兜底裁剪：超窄模式下任何子视图都不得越出侧栏边界。
        .clipped()
    }

    /// 顶部区：仅为左上角三色按钮留白（“+”已下沉到标签列表末尾）。
    private var header: some View {
        Color.clear
            .frame(height: Theme.Metrics.sidebarHeaderHeight)
    }

    /// 顶部控制行：超窄/展开按钮 + 三个固定宽度档位按钮，始终右对齐。
    /// 超窄模式放不下标准尺寸的四个按钮，此时按钮改用紧凑尺寸（不是隐藏），保持与标准档一致的样式结构。
    private var collapseRow: some View {
        HStack(spacing: sidebarCollapsed ? 2 : 4) {
            collapseButton
            ForEach(Theme.SidebarWidthMode.allCases) { mode in
                SidebarWidthModeButton(mode: mode,
                                       isSelected: !sidebarCollapsed && widthMode == mode,
                                       isCompact: sidebarCollapsed) {
                    selectWidthMode(mode)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, Theme.Metrics.listPadding)
        .frame(height: 24)
        // 进入 / 退出超窄模式时按钮尺寸与间距随侧栏宽度一起过渡。
        .animation(Theme.Motion.sidebarResize, value: sidebarCollapsed)
    }

    /// 超窄/展开按钮：不随标签列表滚动，样式与底部设置按钮一致（悬停高亮 + 手指光标）。
    private var collapseButton: some View {
        Button(action: toggleCollapsed) {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 12, weight: .medium))
                // 超窄模式也算一个「选中档位」，与三个宽度档位使用同一套选中高亮。
                .foregroundStyle(sidebarCollapsed ? Color.accentColor
                                 : (isCollapseHovering ? Color.primary : Color.secondary))
                .frame(width: sidebarCollapsed ? 20 : 24, height: sidebarCollapsed ? 20 : 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(sidebarCollapsed ? Color.accentColor.opacity(0.16)
                              : (isCollapseHovering ? Theme.Palette.hoverOverlay : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarModeButtonStyle())
        .onHover { isCollapseHovering = $0 }
        .animation(Theme.Motion.micro, value: isCollapseHovering)
        .pointingHandOnHover()
        .help(sidebarCollapsed ? "展开侧栏" : "切换到超窄模式")
        .accessibilityLabel(sidebarCollapsed ? "展开侧栏" : "切换到超窄模式")
    }

    /// 超窄态点击展开按钮一律回到「默认（标准）宽度」档，而不是恢复上次的加宽档：
    /// 回到一个确定、可预期的状态，比记住历史档位更直观。
    private func toggleCollapsed() {
        withAnimation(Theme.Motion.content) {
            if sidebarCollapsed {
                // 先落档位再展开：超窄态下档位不影响生效宽度，可保证宽度从超窄一步到标准，
                // 避免先按旧档位展开再缩回标准档的两段动画。
                widthMode = .standard
                sidebarCollapsed = false
            } else {
                sidebarCollapsed = true
            }
        }
    }

    private func selectWidthMode(_ mode: Theme.SidebarWidthMode) {
        guard widthMode != mode || sidebarCollapsed else { return }
        withAnimation(Theme.Motion.content) {
            // 先落档位再退出超窄模式，保证宽度从超窄一步到目标档。
            widthMode = mode
            sidebarCollapsed = false
        }
    }

    /// 竖向标签列表：用 `.scrollIndicators(.never)` 彻底移除原生滚动条
    /// （`.hidden` 仅自动隐藏，系统“始终显示”下仍会保留 legacy 白色轨道），
    /// 改用跟随滚动位置的自绘细胶囊指示条。
    private var tabList: some View {
        ScrollView(.vertical) {
            VStack(spacing: Theme.Metrics.tabGap) {
                ForEach(tabManager.layoutRows) { row in
                    tabRowView(row)
                }
                NewTabButton()
            }
            .padding(.horizontal, Theme.Metrics.listPadding)
            .padding(.bottom, Theme.Metrics.listPadding)
            // 顺序变化（增删 / 拖拽落下）时的平滑重排。
            .animation(Theme.Motion.layout, value: tabManager.layoutRows.map(\.id))
        }
        .scrollIndicators(.never)
        .scrollContentBackground(.hidden)
        // 超窄模式下裁掉列表内容横向溢出，避免标题等子视图露到侧栏外。
        .clipped()
        // 自绘滚动指示条（与 SSH/SFTP 文件列表共用，见 Core/DesignSystem/ScrollIndicator.swift）。
        .scrollIndicatorBar()
        .coordinateSpace(name: TabDragSpace.name)
        .onPreferenceChange(TabRowFramesKey.self) { value in
            // 拖拽期间冻结帧快照，避免避让偏移→帧变化→重算落点的反馈循环。
            if drag.draggedID == nil, value.frames != liveRowFrames {
                liveRowFrames = value.frames
            }
        }
        .overlay {
            TabDragPreviewOverlay(coordinator: drag)
        }
    }

    @ViewBuilder
    private func tabRowView(_ row: TabManager.Row) -> some View {
        let offset = drag.avoidanceOffset(for: row.id)
        Group {
            switch row.kind {
            case .groupHeader(let group):
                GroupChipView(group: group, members: row.groupMembers)
                    .transition(Theme.Transitions.chip)
            case .tab(let tab):
                TabItemView(tab: tab, coordinator: drag, liveFrames: liveRowFrames)
                    // 被拖起时原位留一个淡“残影”占位，浮动预览另行跟随指针。
                    .opacity(drag.draggedID == tab.id ? Theme.Palette.dragGhostOpacity : 1)
                    .transition(Theme.Transitions.tabItem)
            }
        }
        .background(rowFrameReporter(id: row.id))
        .offset(y: offset)
        .animation(Theme.Motion.drag, value: offset)
    }

    /// 上报单行在侧栏坐标空间中的位置，用于拖拽开始时建立布局快照。
    private func rowFrameReporter(id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: TabRowFramesKey.self,
                value: TabRowFrames(frames: [id: proxy.frame(in: .named(TabDragSpace.name)).origin])
            )
        }
    }
}

/// 跟随指针的浮动拖拽预览层。
///
/// 独立成 View：拖拽时只有本层读取 `previewTopY/previewShiftX`，
/// 因此每次鼠标移动只重绘这个很小的预览，而不会触发整个标签列表重算，保证拖拽顺滑。
/// 宽度不取固定令牌而是就地测量——侧栏宽度可调整，预览必须与真实行等宽。
private struct TabDragPreviewOverlay: View {
    @Environment(AppState.self) private var appState
    let coordinator: TabDragCoordinator

    var body: some View {
        if let draggedID = coordinator.draggedID,
           let tab = appState.tabManager.tabs.first(where: { $0.id == draggedID }) {
            let groupColor = tab.groupID.flatMap { gid in
                appState.tabManager.groups.first(where: { $0.id == gid })?.color.swiftUIColor
            }
            GeometryReader { proxy in
                let rowWidth = proxy.size.width - Theme.Metrics.listPadding * 2
                TabDragPreviewView(tab: tab, groupColor: groupColor)
                    .frame(width: rowWidth)
                    .position(
                        x: proxy.size.width / 2 + coordinator.previewShiftX,
                        y: coordinator.previewTopY + Theme.Metrics.tabRowHeight / 2
                    )
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - 宽度档位按钮

/// 单个档位按钮：自绘「窗口 + 左侧填充条」图标，填充条越宽表示侧栏越宽。
/// 悬停态放在本视图内部，避免鼠标在按钮间移动时重算整个 TabBarView.body。
private struct SidebarWidthModeButton: View {
    let mode: Theme.SidebarWidthMode
    let isSelected: Bool
    /// 超窄模式下的紧凑尺寸：四个按钮要挤进标准档一半的宽度。
    let isCompact: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            SidebarWidthGlyph(mode: mode,
                              tint: isSelected ? Color.accentColor : Color.primary)
                .frame(width: isCompact ? 20 : 24, height: isCompact ? 20 : 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(background)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarModeButtonStyle())
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.micro, value: isHovering)
        .animation(Theme.Motion.micro, value: isSelected)
        .pointingHandOnHover()
        .help(mode.label)
        .accessibilityLabel(mode.label)
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovering { return Theme.Palette.hoverOverlay }
        return Color.clear
    }
}

/// 档位按钮按压反馈：按下轻微缩小并变淡，松手弹回，与侧栏伸缩的手感呼应。
private struct SidebarModeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Theme.Motion.micro, value: configuration.isPressed)
    }
}

/// 一个 15×12 的窗口轮廓，左侧实心条宽度按档位递增（4 / 6 / 8）。
private struct SidebarWidthGlyph: View {
    let mode: Theme.SidebarWidthMode
    let tint: Color

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(tint.opacity(0.45), lineWidth: 1)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint)
                .frame(width: mode.glyphFill, height: 9)
                .padding(.leading, 1.5)
        }
        .frame(width: 15, height: 12)
    }
}

// MARK: - Sidebar background

/// 侧栏背景：材质。
private struct TabBarBackground: View {
    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
    }
}

#Preview {
    HStack(spacing: 0) {
        TabBarView().frame(width: Theme.Metrics.sidebarWidth)
        Divider()
        Color.clear
    }
    .environment(AppState.shared)
    .frame(width: 700, height: 500)
}
