//
//  JSONTool.swift
//  devkit
//
//  JSON Studio（M3 完整实现；M1 提供 descriptor 与占位视图）。
//

import SwiftUI

@Observable
final class JSONTool: DevkitTool {
    static let descriptor = ToolDescriptor(
        id: "tool.json",
        title: "JSON 工具",
        symbolName: "curlybraces",
        category: .data,
        subtitle: "文本 / 树形双视图编辑、格式化、Diff、JSONPath、格式转换。",
        allowsMultipleInstances: true,
        supportsWindowDetach: true
    )

    var descriptor: ToolDescriptor { Self.descriptor }

    /// 当前文档名；M3 支持另存为后自动升级标题。
    var documentName: String = ""

    var dynamicTabTitle: String? {
        documentName.isEmpty ? nil : documentName
    }

    var hasUnsavedContent: Bool { !documentName.isEmpty }

    init() {}

    @MainActor func makeView() -> AnyView {
        AnyView(JSONToolView(tool: self))
    }
}

private struct JSONToolView: View {
    @Bindable var tool: JSONTool

    var body: some View {
        ToolPlaceholderView(
            descriptor: tool.descriptor,
            milestone: "M3",
            bullets: [
                "双视图：文本编辑器（语法高亮 / 行号 / 括号配对） + 树形视图（可折叠 / 路径面包屑）双向同步",
                "大文件 >10MB 自动懒加载 / 虚拟滚动",
                "格式化 / 压缩 / 校验 / 键排序",
                "JSON ↔ YAML / XML / CSV / TOML 双向转换",
                "JSONPath 表达式过滤，命中节点高亮，可抽子树为新文档",
                "结构化 JSON Diff（忽略键顺序可配置）",
                "转义 / 反转义；节点数、深度、类型分布",
                "历史快照与一键回退",
            ]
        )
    }
}
