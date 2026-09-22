//
//  ToolProtocol.swift
//  devkit
//
//  工具注册协议：所有工具实现统一接口，Shell 只负责装配。
//

import SwiftUI

/// 工具静态描述：图标、名称、能力声明。所有工具实例共享一份。
struct ToolDescriptor: Identifiable, Hashable {
    /// 工具唯一 ID，用作持久化 key（不可变更）。
    let id: String
    /// 工具显示名称，如 "HTTP 请求"。
    let title: String
    /// SF Symbol 名称。
    let symbolName: String
    /// 工具分类（Launcher 分组展示）。
    let category: ToolCategory
    /// 简短描述（Launcher 卡片副标题）。
    let subtitle: String
    /// 是否允许多实例（多个标签同时打开）。
    let allowsMultipleInstances: Bool
    /// 是否支持将标签拖出为独立窗口。
    let supportsWindowDetach: Bool

    enum ToolCategory: String, CaseIterable, Hashable {
        case network  = "网络"
        case terminal = "终端"
        case data     = "数据"
        case utility  = "实用工具"
    }
}

/// 工具运行时协议：每个工具实现此协议以向 Shell 提供视图与动态标题。
///
/// Shell 通过 `ToolRegistry` 拿到 descriptor，创建对应实例；实例负责输出视图与标题。
/// 视图工厂返回值会被塞入 tab 内容区。
protocol DevkitTool: AnyObject {
    /// 与该实例绑定的 descriptor（通常与工具类型对应）。
    var descriptor: ToolDescriptor { get }

    /// 动态标签标题；返回 nil 时 Shell 使用 `descriptor.title` 作为默认标题。
    /// 例如 HTTP 工具可返回当前请求的 host，JSON 工具可返回文档名。
    var dynamicTabTitle: String? { get }

    /// 标签是否有未保存内容（关闭时提醒）。
    var hasUnsavedContent: Bool { get }

    // MARK: - 保存工作流（M5，可选能力；默认全部关闭，工具按需覆写）

    /// 是否支持 ⌘S 保存（如 HTTP 工具）。Shell 据此决定是否响应保存。
    var supportsSave: Bool { get }
    /// 当前内容是否已关联到一条已保存记录（决定 ⌘S 是原地更新还是弹框另存）。
    var isSaved: Bool { get }
    /// 原地保存到既有记录；仅在 `isSaved` 为真时由 Shell 调用。未保存时由 Shell 走弹框另存路径。
    @MainActor func saveViaShell() throws

    /// 构造工具主视图。
    @MainActor func makeView() -> AnyView

    // MARK: - 会话持久化（可选：工具把内部可变状态随标签快照存/取，默认不参与）

    /// 将工具内部状态编码为随标签一起持久化的 Data；返回 nil 表示无需持久化。
    @MainActor func sessionStateData() -> Data?
    /// 从快照恢复工具内部状态（App 重启后重建标签时调用）。
    @MainActor func restoreSessionState(_ data: Data)
}

extension DevkitTool {
    var supportsSave: Bool { false }
    var isSaved: Bool { false }
    @MainActor func saveViaShell() throws {}
    @MainActor func sessionStateData() -> Data? { nil }
    @MainActor func restoreSessionState(_ data: Data) {}
}
