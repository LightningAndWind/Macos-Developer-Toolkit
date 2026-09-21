//
//  HTTPTool.swift
//  devkit
//
//  HTTP 请求工具（M2 完整实现；M1 提供 descriptor 与占位视图）。
//

import SwiftUI

@Observable
final class HTTPTool: DevkitTool {
    static let descriptor = ToolDescriptor(
        id: "tool.http",
        title: "HTTP 请求",
        symbolName: "arrow.up.arrow.down.square",
        category: .network,
        subtitle: "构造并发送 HTTP 请求，查看响应、集合与环境变量。",
        allowsMultipleInstances: true,
        supportsWindowDetach: true
    )

    var descriptor: ToolDescriptor { Self.descriptor }

    /// M2 中会绑定当前请求 URL 的 host。
    var requestURLString: String = ""

    var dynamicTabTitle: String? {
        guard let host = URL(string: requestURLString)?.host, !host.isEmpty else { return nil }
        return host
    }

    var hasUnsavedContent: Bool {
        !requestURLString.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {}

    @MainActor func makeView() -> AnyView {
        AnyView(HTTPToolView(tool: self))
    }
}

private struct HTTPToolView: View {
    @Bindable var tool: HTTPTool

    var body: some View {
        ToolPlaceholderView(
            descriptor: tool.descriptor,
            milestone: "M2",
            bullets: [
                "GET / POST / PUT / DELETE / PATCH + 自定义方法",
                "Params / Headers / Body 分区编辑（JSON / form / multipart / raw / GraphQL）",
                "Bearer Token / Basic Auth 快捷",
                "响应：状态码颜色分级、耗时、大小；Pretty / Raw / Preview / Headers 视图",
                "cURL 导入 / 导出",
                "历史记录、集合（Collections）、环境变量 `{{var}}`",
            ]
        )
    }
}
