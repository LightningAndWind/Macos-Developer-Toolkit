//
//  TabManager.swift
//  devkit
//
//  标签生命周期与分组管理。M1 主实现，UI 与命令都通过这里下发。
//

import Foundation
import SwiftUI

/// 单个窗口的标签集合管理器。
///
/// 一个 TabManager 对应一个窗口；M1 只有一个主窗口，字段设计允许多窗口扩展。
@Observable
final class TabManager {
    // MARK: - State

    private(set) var tabs: [Tab] = []
    private(set) var groups: [TabGroup] = []
    var selectedTabID: UUID?
    /// 是否展示 Launcher（无 tab 或用户点击 +）。
    var isLauncherPresented: Bool = true

    // MARK: - Derived

    var selectedTab: Tab? {
        guard let id = selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var hasTabs: Bool { !tabs.isEmpty }

    /// 按 UI 顺序展开的行：分组头 + 组内 tab（折叠时不输出成员） + 未分组 tab。
    struct Row: Identifiable {
        enum Kind { case groupHeader(TabGroup), tab(Tab) }
        let id: UUID
        let kind: Kind
        /// 分组行时给出组内成员，用于渲染胶囊与拖拽落点。
        let groupMembers: [Tab]
    }

    /// 展平后的渲染顺序。同组 tab 相邻，非组 tab 保持插入序。
    var layoutRows: [Row] {
        var rows: [Row] = []
        var visitedGroups = Set<UUID>()
        for tab in tabs {
            if let gid = tab.groupID, let group = groups.first(where: { $0.id == gid }) {
                if !visitedGroups.contains(gid) {
                    visitedGroups.insert(gid)
                    let members = tabs.filter { $0.groupID == gid }
                    rows.append(Row(id: group.id, kind: .groupHeader(group), groupMembers: members))
                }
                if !group.isCollapsed {
                    rows.append(Row(id: tab.id, kind: .tab(tab), groupMembers: []))
                }
            } else {
                rows.append(Row(id: tab.id, kind: .tab(tab), groupMembers: []))
            }
        }
        return rows
    }

    // MARK: - Open / Close / Select

    /// 打开一个工具的新标签。
    @discardableResult
    func openTool(descriptor: ToolDescriptor, customTitle: String? = nil) -> Tab? {
        // 单实例工具：若已存在则聚焦。
        if !descriptor.allowsMultipleInstances,
           let existing = tabs.first(where: { $0.toolID == descriptor.id }) {
            select(existing.id)
            isLauncherPresented = false
            return existing
        }
        guard let instance = ToolRegistry.shared.makeTool(id: descriptor.id) else { return nil }
        let tab = Tab(toolID: descriptor.id, customTitle: customTitle, toolInstance: instance)
        tabs.append(tab)
        select(tab.id)
        isLauncherPresented = false
        return tab
    }

    /// 关闭标签；调用方应先处理未保存提醒。
    func close(tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let closing = tabs[idx]
        if closing.toolInstance?.hasUnsavedContent == true {
            // M1 简化：调用方负责在此之前弹框。这里仅暴露 `hasUnsavedContent` 检查 API。
        }
        tabs.remove(at: idx)
        // 清理空组
        if let gid = closing.groupID,
           !tabs.contains(where: { $0.groupID == gid }),
           let gIdx = groups.firstIndex(where: { $0.id == gid }) {
            groups.remove(at: gIdx)
        }
        // 选中邻居
        if selectedTabID == tabID {
            if tabs.isEmpty {
                selectedTabID = nil
                isLauncherPresented = true
            } else {
                let newIdx = min(idx, tabs.count - 1)
                selectedTabID = tabs[newIdx].id
            }
        }
    }

    func select(_ id: UUID) {
        selectedTabID = id
        isLauncherPresented = false
    }

    func selectNext(wrap: Bool = true) {
        guard !tabs.isEmpty, let cur = selectedTabID,
              let idx = tabs.firstIndex(where: { $0.id == cur }) else {
            selectedTabID = tabs.first?.id
            return
        }
        let next = (idx + 1) % tabs.count
        selectedTabID = tabs[next].id
        _ = wrap
    }

    func selectPrevious(wrap: Bool = true) {
        guard !tabs.isEmpty, let cur = selectedTabID,
              let idx = tabs.firstIndex(where: { $0.id == cur }) else {
            selectedTabID = tabs.last?.id
            return
        }
        let prev = (idx - 1 + tabs.count) % tabs.count
        selectedTabID = tabs[prev].id
        _ = wrap
    }

    /// ⌘1~9 直达第 N 个标签；0 表示最后一个。
    func selectAt(position: Int) {
        guard !tabs.isEmpty else { return }
        let idx: Int
        if position == 0 { idx = tabs.count - 1 }
        else { idx = min(position - 1, tabs.count - 1) }
        selectedTabID = tabs[idx].id
        isLauncherPresented = false
    }

    // MARK: - Rename

    func rename(tabID: UUID, to title: String) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tab.customTitle = title.isEmpty ? nil : title
    }

    // MARK: - Groups

    /// 将指定 tabs 归入新分组。
    @discardableResult
    func createGroup(with tabIDs: [UUID], name: String, color: TabGroup.GroupColor) -> TabGroup? {
        guard !tabIDs.isEmpty else { return nil }
        let group = TabGroup(name: name, color: color)
        groups.append(group)
        for id in tabIDs {
            tabs.first(where: { $0.id == id })?.groupID = group.id
        }
        // 保证同组 tab 相邻：把成员紧跟在组首个 tab 之后。
        normalizeGroupOrdering()
        return group
    }

    /// 把 tab 移入已有分组；`groupID = nil` 表示移出分组。
    func move(tabID: UUID, to groupID: UUID?) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let previousGroupID = tab.groupID
        tab.groupID = groupID
        if let previousGroupID, previousGroupID != groupID,
           !tabs.contains(where: { $0.groupID == previousGroupID }) {
            groups.removeAll { $0.id == previousGroupID }
        }
        if groupID != nil { normalizeGroupOrdering() }
        pruneEmptyGroups()
    }

    func rename(groupID: UUID, to name: String) {
        groups.first(where: { $0.id == groupID })?.name = name
    }

    func setGroupColor(groupID: UUID, color: TabGroup.GroupColor) {
        groups.first(where: { $0.id == groupID })?.color = color
    }

    func toggleGroupCollapsed(groupID: UUID) {
        guard let g = groups.first(where: { $0.id == groupID }) else { return }
        g.isCollapsed.toggle()
    }

    func closeGroup(_ groupID: UUID) {
        let ids = tabs.filter { $0.groupID == groupID }.map(\.id)
        for id in ids { close(tabID: id) }
    }

    // MARK: - Reorder (drag & drop)

    /// 把 tabID 移动到 targetIndex（tabs 数组索引）。
    func move(tabID: UUID, toIndex targetIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let clamped = max(0, min(targetIndex, tabs.count - 1))
        guard from != clamped else { return }
        let item = tabs.remove(at: from)
        tabs.insert(item, at: clamped)
        normalizeGroupOrdering()
    }

    /// 拖拽重排：把 draggedID 标签移动到 targetID 标签所在的位置。
    func reorder(draggedID: UUID, to targetID: UUID) {
        guard draggedID != targetID,
              let from = tabs.firstIndex(where: { $0.id == draggedID }),
              let to = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        let item = tabs.remove(at: from)
        let insertAt = max(0, min(to, tabs.count))
        tabs.insert(item, at: insertAt)
        normalizeGroupOrdering()
    }

    /// 拖拽落下：一次性完成“重排 + 分组归属”变更。
    ///
    /// - `targetTabID`：落点参照的标签（落在分组头时为 nil）。
    /// - `targetGroupID`：落点所属分组（落在未分组区域时为 nil）。
    /// 直接精确插入，避免 `normalizeGroupOrdering()` 把成员拉回组首而丢失落点位置。
    func drop(draggedID: UUID, targetTabID: UUID?, targetGroupID: UUID?) {
        guard let from = tabs.firstIndex(where: { $0.id == draggedID }) else { return }
        // 落回自身：无操作。
        if targetTabID == draggedID { return }

        // 关键：落点参照标签的“原始索引”（移除拖拽项之前）。
        // 向下拖（from < target）时移除会使 target 左移一位，插到 targetOriginal 恰好落在其后；
        // 向上拖（from > target）时 target 不受移除影响，插到 targetOriginal 恰好落在其前。
        // 两种情况都让拖拽项落入避让动画让出的那个空位。
        let targetOriginalIndex = targetTabID.flatMap { id in tabs.firstIndex(where: { $0.id == id }) }

        let dragged = tabs.remove(at: from)
        let previousGroupID = dragged.groupID
        dragged.groupID = targetGroupID

        let insertAt: Int
        if let targetOriginalIndex {
            insertAt = targetOriginalIndex
        } else if let targetGroupID,
                  let firstMember = tabs.firstIndex(where: { $0.groupID == targetGroupID }) {
            // 落在分组头：插到该组首个成员之前。
            insertAt = firstMember
        } else if targetGroupID != nil {
            // 目标组当前无其他成员（异常兜底）：追加到末尾。
            insertAt = tabs.count
        } else {
            insertAt = min(from, tabs.count)
        }
        tabs.insert(dragged, at: max(0, min(insertAt, tabs.count)))

        // 原分组若因此变空则移除。
        if let previousGroupID, previousGroupID != targetGroupID,
           !tabs.contains(where: { $0.groupID == previousGroupID }) {
            groups.removeAll { $0.id == previousGroupID }
        }
        pruneEmptyGroups()
    }

    // MARK: - Snapshot / Restore

    func snapshot(windowID: UUID) -> WindowSessionSnapshot {
        WindowSessionSnapshot(
            windowID: windowID,
            tabs: tabs.map { TabSnapshot(id: $0.id,
                                         toolID: $0.toolID,
                                         customTitle: $0.customTitle,
                                         groupID: $0.groupID,
                                         isPinned: $0.isPinned,
                                         createdAt: $0.createdAt,
                                         toolState: $0.toolInstance?.sessionStateData()) },
            groups: groups.map { TabGroupSnapshot(id: $0.id,
                                                  name: $0.name,
                                                  colorRaw: $0.color.rawValue,
                                                  isCollapsed: $0.isCollapsed) },
            selectedTabID: selectedTabID
        )
    }

    func restore(_ window: WindowSessionSnapshot) {
        let registry = ToolRegistry.shared
        var newGroups: [TabGroup] = []
        for g in window.groups {
            let color = TabGroup.GroupColor(rawValue: g.colorRaw) ?? .gray
            newGroups.append(TabGroup(id: g.id, name: g.name, color: color, isCollapsed: g.isCollapsed))
        }
        var newTabs: [Tab] = []
        for t in window.tabs {
            guard registry.descriptor(for: t.toolID) != nil else { continue }
            let instance = registry.makeTool(id: t.toolID)
            if let data = t.toolState { instance?.restoreSessionState(data) }
            let tab = Tab(id: t.id,
                          toolID: t.toolID,
                          customTitle: t.customTitle,
                          groupID: t.groupID,
                          createdAt: t.createdAt,
                          toolInstance: instance)
            tab.isPinned = t.isPinned
            newTabs.append(tab)
        }
        self.groups = newGroups
        self.tabs = newTabs
        self.selectedTabID = window.selectedTabID ?? newTabs.first?.id
        self.isLauncherPresented = newTabs.isEmpty
    }

    // MARK: - Private

    private func pruneEmptyGroups() {
        groups.removeAll { g in !tabs.contains(where: { $0.groupID == g.id }) }
    }

    /// 保证同一 group 的 tab 在 tabs 数组中相邻，且按 group 首次出现的顺序排列。
    private func normalizeGroupOrdering() {
        var seen = Set<UUID>()
        var result: [Tab] = []
        var usedIDs = Set<UUID>()
        for tab in tabs {
            if usedIDs.contains(tab.id) { continue }
            if let gid = tab.groupID, !seen.contains(gid) {
                seen.insert(gid)
                let members = tabs.filter { $0.groupID == gid && !usedIDs.contains($0.id) }
                result.append(contentsOf: members)
                usedIDs.formUnion(members.map(\.id))
            } else if tab.groupID == nil {
                result.append(tab)
                usedIDs.insert(tab.id)
            }
        }
        // 兜底：加入未处理的（如 groupID 指向不存在的组）
        for tab in tabs where !usedIDs.contains(tab.id) {
            result.append(tab)
        }
        tabs = result
    }
}
