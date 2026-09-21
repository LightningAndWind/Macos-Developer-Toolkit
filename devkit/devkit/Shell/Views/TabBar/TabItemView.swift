//
//  TabItemView.swift
//  devkit
//
//  竖向标签行：整行宽度，左侧分组色条 + 图标 + 标题 + 尾部关闭按钮。
//  单击选中、双击重命名、悬停高亮；支持 Chrome 风格拖拽排序
//  （本行以浮动预览跟随指针，其他标签实时避让，可直接拖入分组）。
//

import SwiftUI

struct TabItemView: View {
    @Environment(AppState.self) private var appState
    let tab: Tab
    /// 跨行共享的拖拽协调器（由 TabBarView 注入）。
    let coordinator: TabDragCoordinator
    /// 各行的实时帧快照来源（由 TabBarView 注入）。
    let liveFrames: [UUID: CGRect]

    @State private var isHovering = false
    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    /// 手动双击判定：记录上一次单击时间，避免用 count:2 手势拖慢单击。
    @State private var lastTapDate: Date?
    @FocusState private var titleFieldFocused: Bool

    private var isSelected: Bool { appState.tabManager.selectedTabID == tab.id }

    private var groupColor: Color? {
        guard let gid = tab.groupID,
              let g = appState.tabManager.groups.first(where: { $0.id == gid })
        else { return nil }
        return g.color.swiftUIColor
    }

    private var symbolName: String {
        ToolRegistry.shared.descriptor(for: tab.toolID)?.symbolName ?? "questionmark.app"
    }

    var body: some View {
        HStack(spacing: Theme.Metrics.tabInnerSpacing) {
            if let groupColor {
                RoundedRectangle(cornerRadius: 2)
                    .fill(groupColor)
                    .frame(width: Theme.Metrics.groupAccentWidth)
            }
            Image(systemName: symbolName)
                .font(Theme.Fonts.tabSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            titleView
        }
        .padding(.horizontal, Theme.Metrics.tabHPadding)
        .frame(height: Theme.Metrics.tabRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(backgroundShape)
        .overlay(borderStroke)
        // 统一手势作用于行内容；关闭按钮随后叠在其上，独立命中，互不干扰。
        .gesture(rowGesture)
        .overlay(alignment: .trailing) {
            if isHovering || isSelected {
                closeButton
                    .padding(.trailing, Theme.Metrics.tabHPadding - 3)
            }
        }
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.micro, value: isSelected)
        .animation(Theme.Motion.micro, value: isHovering)
        .contextMenu { menu }
        .help(tab.displayTitle)
    }

    /// 统一手势：单个 `DragGesture(minimumDistance: 0)` 同时处理点击 / 双击 / 拖拽。
    ///
    /// 相比“`.onTapGesture` + 独立拖拽手势”，单一手势从鼠标按下的那一刻就接管交互，
    /// 不需等待与点击手势仲裁，拖拽起步无延迟、更跟手；点击与双击在 `onEnded` 里根据位移区分。
    private var rowGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(TabDragSpace.name))
            .onChanged { value in
                // 重命名进行中时不处理，避免抢占 TextField 的鼠标选择。
                guard !isEditingTitle else { return }
                if coordinator.draggedID == nil {
                    let t = value.translation
                    let threshold = Theme.Metrics.dragMinimumDistance
                    // 未超阈值：暂不起拖，等 onEnded 当作点击处理。
                    guard (t.width * t.width + t.height * t.height) > threshold * threshold else { return }
                    coordinator.beginDrag(tabID: tab.id,
                                          rows: appState.tabManager.layoutRows,
                                          frames: liveFrames,
                                          location: value.startLocation)
                }
                coordinator.updateDrag(location: value.location)
            }
            .onEnded { _ in
                guard !isEditingTitle else { return }
                if coordinator.draggedID != nil {
                    commitDrop()
                } else {
                    handleTap()
                }
            }
    }

    /// 瞬时提交拖拽落位（禁用动画，与浮动预览无缝衔接），并选中被拖标签。
    private func commitDrop() {
        let rows = appState.tabManager.layoutRows
        var transaction = Transaction()
        transaction.disablesAnimations = true
        var dragged: UUID?
        withTransaction(transaction) {
            guard let result = coordinator.endDrag(rows: rows) else { return }
            appState.tabManager.drop(draggedID: result.draggedID,
                                     targetTabID: result.targetTabID,
                                     targetGroupID: result.targetGroupID)
            dragged = result.draggedID
        }
        if let dragged {
            appState.tabManager.select(dragged)
            appState.saveSession()
        }
    }

    /// 单击立即选中；若两次点击间隔小于系统双击阈值则视为双击→重命名。
    private func handleTap() {
        let now = Date()
        if let last = lastTapDate, now.timeIntervalSince(last) < Self.doubleTapInterval {
            lastTapDate = nil
            beginRename()
        } else {
            appState.tabManager.select(tab.id)
            lastTapDate = now
        }
    }

    /// 双击判定阈值：跟随系统「通用 → 双击速度」偏好（全局域 `AppleDoubleClickInterval`）。
    private static var doubleTapInterval: TimeInterval {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        if let raw = global?["AppleDoubleClickInterval"] as? NSNumber {
            let value = raw.doubleValue
            if value > 0 { return value }
        }
        return 0.5
    }

    // MARK: - Sub views

    @ViewBuilder
    private var titleView: some View {
        if isEditingTitle {
            TextField("标签标题", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.tabTitle)
                .focused($titleFieldFocused)
                .onSubmit(commitRename)
        } else {
            Text(tab.displayTitle)
                .font(Theme.Fonts.tabTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var closeButton: some View {
        Button(action: requestClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("关闭 (⌘W)")
    }

    @ViewBuilder
    private var backgroundShape: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.tabCornerRadius)
        if isSelected {
            shape.fill(Theme.Palette.tabSelected)
        } else if isHovering {
            shape.fill(Theme.Palette.hoverOverlay)
        } else if let groupColor {
            shape.fill(groupColor.opacity(0.10))
        } else {
            shape.fill(Color.clear)
        }
    }

    @ViewBuilder
    private var borderStroke: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Metrics.tabCornerRadius)
                .strokeBorder(Theme.Palette.accentStroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("重命名…", action: beginRename)
        Divider()
        Menu("添加到分组") {
            Button("新建分组…") { createNewGroup() }
            if !appState.tabManager.groups.isEmpty {
                Divider()
                ForEach(appState.tabManager.groups) { g in
                    Button(g.name) {
                        withAnimation(Theme.Motion.layout) {
                            appState.tabManager.move(tabID: tab.id, to: g.id)
                        }
                        appState.saveSession()
                    }
                }
            }
        }
        if tab.groupID != nil {
            Button("从分组中移除") {
                withAnimation(Theme.Motion.layout) {
                    appState.tabManager.move(tabID: tab.id, to: nil)
                }
                appState.saveSession()
            }
        }
        Divider()
        Button("关闭标签", role: .destructive, action: requestClose)
    }

    // MARK: - Actions

    private func beginRename() {
        draftTitle = tab.displayTitle
        isEditingTitle = true
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    private func commitRename() {
        appState.tabManager.rename(tabID: tab.id, to: draftTitle)
        appState.saveSession()
        isEditingTitle = false
    }

    private func createNewGroup() {
        let color = TabGroup.GroupColor.allCases.randomElement() ?? .gray
        withAnimation(Theme.Motion.layout) {
            _ = appState.tabManager.createGroup(with: [tab.id], name: "分组", color: color)
        }
        appState.saveSession()
    }

    private func requestClose() {
        if tab.toolInstance?.hasUnsavedContent == true {
            appState.pendingCloseTabID = tab.id
        } else {
            withAnimation(Theme.Motion.layout) {
                appState.closeTab(tab.id)
            }
        }
    }
}
