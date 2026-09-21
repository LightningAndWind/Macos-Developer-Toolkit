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

    /// 构造工具主视图。
    @MainActor func makeView() -> AnyView
}
