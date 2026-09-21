//
//  Tab.swift
//  devkit
//
//  标签数据模型：一个 Tab 表示工具的一次实例化。
//

import Foundation

/// 标签模型（值类型 + 引用型工具实例）。
@Observable
final class Tab: Identifiable, Hashable {
    let id: UUID
    /// 关联的工具 ID（对应 `ToolDescriptor.id`）。
    let toolID: String
    /// 用户或工具动态计算得到的标题；优先级：customTitle > toolDynamicTitle > descriptor.title
    var customTitle: String?
    /// 所属分组 ID；nil 表示未分组。
    var groupID: UUID?
    /// 是否被固定（pin）——M1 仅暴露字段，UI 稍后使用。
    var isPinned: Bool = false
    /// 创建时间，用于最近使用排序。
    let createdAt: Date

    /// 关联的工具实例（运行时对象）。
    @ObservationIgnored var toolInstance: DevkitTool?

    init(id: UUID = UUID(),
         toolID: String,
         customTitle: String? = nil,
         groupID: UUID? = nil,
         createdAt: Date = .now,
         toolInstance: DevkitTool? = nil) {
        self.id = id
        self.toolID = toolID
        self.customTitle = customTitle
        self.groupID = groupID
        self.createdAt = createdAt
        self.toolInstance = toolInstance
    }

    /// 展示给标签栏的最终标题。
    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let dyn = toolInstance?.dynamicTabTitle, !dyn.isEmpty { return dyn }
        return ToolRegistry.shared.descriptor(for: toolID)?.title ?? "未知工具"
    }

    static func == (lhs: Tab, rhs: Tab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
