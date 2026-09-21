//
//  SSHTool.swift
//  devkit
//
//  SSH / SFTP 工具（M4/M5 完整实现；M1 提供 descriptor 与占位视图）。
//

import SwiftUI

@Observable
final class SSHTool: DevkitTool {
    static let descriptor = ToolDescriptor(
        id: "tool.ssh",
        title: "SSH 终端",
        symbolName: "terminal",
        category: .terminal,
        subtitle: "基于 SwiftTerm 的终端与 SFTP 双栏文件管理。",
        allowsMultipleInstances: true,
        supportsWindowDetach: true
    )

    var descriptor: ToolDescriptor { Self.descriptor }

    /// 当前会话主机名；M4 中由 SSHClient 更新。
    var hostName: String = ""

    var dynamicTabTitle: String? {
        hostName.isEmpty ? nil : hostName
    }

    /// 终端会话视为运行中，关闭需确认。M1 简化为 false。
    var hasUnsavedContent: Bool { false }

    init() {}

    @MainActor func makeView() -> AnyView {
        AnyView(SSHToolView(tool: self))
    }
}

private struct SSHToolView: View {
    @Bindable var tool: SSHTool

    var body: some View {
        ToolPlaceholderView(
            descriptor: tool.descriptor,
            milestone: "M4",
            bullets: [
                "Profiles 侧栏：主机 / 端口 / 用户名 / 认证方式（密码、私钥、ssh-agent）",
                "凭据存 macOS Keychain；支持导入 ~/.ssh/config",
                "SwiftTerm 终端：xterm-256color、VT 转义序列、分屏、字体配色、链接点击、缓冲区搜索",
                "终端 cd 时 SFTP 面板跟随远端目录",
                "SFTP：与 SSH 会话关联的双栏文件管理器；拖拽上传/下载、进度、失败重试",
            ]
        )
    }
}
