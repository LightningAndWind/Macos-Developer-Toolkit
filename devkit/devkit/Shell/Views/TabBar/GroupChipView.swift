//
//  GroupChipView.swift
//  devkit
//
//  竖向分组行：颜色圆点 + 名称 + 成员数 + 折叠箭头。点击切换折叠/展开。
//

import SwiftUI

struct GroupChipView: View {
    @Environment(AppState.self) private var appState
    let group: TabGroup
    let members: [Tab]

    @State private var isHovering = false

    /// 分组折叠且选中标签在组内：成员行不可见，由分组行代显选中态。
    private var containsSelectedTab: Bool {
        guard group.isCollapsed, let selectedID = appState.tabManager.selectedTabID else { return false }
        return members.contains { $0.id == selectedID }
    }

    /// 背景浓度：悬停 > 代显选中 > 常态。
    private var fillOpacity: Double {
        if isHovering { return 0.22 }
        if containsSelectedTab { return 0.20 }
        return 0.14
    }

    var body: some View {
        HStack(spacing: Theme.Metrics.tabInnerSpacing) {
            Circle().fill(group.color.swiftUIColor).frame(width: 8, height: 8)
            FadingTitleText(text: group.name, font: Theme.Fonts.tabTitle.weight(.medium))
            Text("\(members.count)")
                .font(Theme.Fonts.badge)
                .foregroundStyle(.secondary)
            Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Metrics.tabHPadding)
        .frame(height: Theme.Metrics.tabRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.tabCornerRadius)
                .fill(group.color.swiftUIColor.opacity(fillOpacity))
        )
        .overlay {
            if containsSelectedTab {
                RoundedRectangle(cornerRadius: Theme.Metrics.tabCornerRadius)
                    .strokeBorder(Theme.Palette.accentStroke, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.micro, value: isHovering)
        .animation(Theme.Motion.micro, value: containsSelectedTab)
        .onTapGesture { toggleCollapsed() }
        .contextMenu { menu }
        .help(group.name)
    }

    @ViewBuilder
    private var menu: some View {
        Button("重命名分组…", action: renameGroup)
        Menu("颜色") {
            ForEach(TabGroup.GroupColor.allCases, id: \.self) { c in
                Button {
                    setGroupColor(c)
                } label: {
                    HStack {
                        Circle().fill(c.swiftUIColor).frame(width: 10, height: 10)
                        Text(c.rawValue)
                    }
                }
            }
        }
        Divider()
        Button("关闭组内全部标签", role: .destructive) { closeGroup() }
    }

    // MARK: - Actions

    private func toggleCollapsed() {
        withAnimation(Theme.Motion.layout) {
            appState.tabManager.toggleGroupCollapsed(groupID: group.id)
        }
        appState.saveSession()
    }

    private func setGroupColor(_ color: TabGroup.GroupColor) {
        appState.tabManager.setGroupColor(groupID: group.id, color: color)
        appState.saveSession()
    }

    private func closeGroup() {
        withAnimation(Theme.Motion.layout) {
            appState.tabManager.closeGroup(group.id)
        }
        appState.saveSession()
    }

    private func renameGroup() {
        let alert = NSAlert()
        alert.messageText = "重命名分组"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: group.name)
        field.frame.size.width += 80
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            appState.tabManager.rename(groupID: group.id, to: field.stringValue)
            appState.saveSession()
        }
    }
}
