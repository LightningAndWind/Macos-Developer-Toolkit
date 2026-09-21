//
//  ToolRegistry.swift
//  devkit
//
//  工具注册中心：Shell 从这里获取所有已注册工具的元数据与实例工厂。
//

import SwiftUI

/// 工具注册中心（进程级单例）。
///
/// 用法：
/// ```
/// ToolRegistry.shared.register(descriptor: HTTPTool.descriptor) { HTTPTool() }
/// ```
@MainActor
final class ToolRegistry {
    static let shared = ToolRegistry()

    private(set) var descriptors: [ToolDescriptor] = []
    private var factories: [String: () -> DevkitTool] = [:]

    private init() {}

    /// 注册一个工具。同 id 会被覆盖。
    func register(descriptor: ToolDescriptor, factory: @escaping () -> DevkitTool) {
        if !descriptors.contains(where: { $0.id == descriptor.id }) {
            descriptors.append(descriptor)
        }
        factories[descriptor.id] = factory
    }

    func descriptor(for id: String) -> ToolDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// 创建一个工具实例。若 id 未注册返回 nil。
    func makeTool(id: String) -> DevkitTool? {
        factories[id]?()
    }

    /// 按分类聚合的 descriptors，供 Launcher 展示。
    var categorizedDescriptors: [(ToolDescriptor.ToolCategory, [ToolDescriptor])] {
        ToolDescriptor.ToolCategory.allCases.compactMap { cat in
            let items = descriptors.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }
}
