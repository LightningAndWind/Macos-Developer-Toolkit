//
//  TabBarView.swift
//  devkit
//
//  左侧竖向标签栏（侧栏）：顶部为三色按钮预留空间，
//  下方竖向列表渲染 layoutRows（分组头 + 标签），末尾追加与标签等大的“+”整行按钮。超出高度显示自绘滚动指示条，支持滚轮。
//  最底部为固定操作条（设置按钮），位于滚动区之外，不随标签列表滚动。
//  侧栏宽度可由用户拖拽分割线调整：行矩形跟随宽度伸缩，标题在窄到装不下时于右缘渐隐（见 FadingTitleText）。
//

import SwiftUI

struct TabBarView: View {
    @Environment(AppState.self) private var appState

    private var tabManager: TabManager { appState.tabManager }

    /// 拖拽协调器：跨行共享的拖拽瞬时状态。
    @State private var drag = TabDragCoordinator()
    /// 各行在侧栏坐标空间中的实时帧（拖拽开始前用于建立布局快照）。
    @State private var liveRowFrames: [UUID: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            tabList
            SidebarFooterBar()
        }
        .frame(maxHeight: .infinity)
        .background(TabBarBackground())
    }

    /// 顶部区：仅为左上角三色按钮留白（“+”已下沉到标签列表末尾）。
    private var header: some View {
        Color.clear
            .frame(height: Theme.Metrics.sidebarHeaderHeight)
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

    /// 上报单行在侧栏坐标空间中的帧，用于拖拽开始时建立布局快照。
    private func rowFrameReporter(id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: TabRowFramesKey.self,
                value: TabRowFrames(frames: [id: proxy.frame(in: .named(TabDragSpace.name))])
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
