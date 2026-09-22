//
//  LocalTerminalContainer.swift
//  devkit
//
//  M4：本地 shell 终端。用 SwiftTerm 的 LocalProcessTerminalView（内部自带 PTY 与进程桥接），
//  在 makeNSView 时启动用户默认 shell。选「本地」的新标签即呈现此视图。
//

import AppKit
import SwiftUI
import SwiftTerm

struct LocalTerminalContainer: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        if let font = NSFont(name: "Menlo", size: 12) { view.font = font }
        view.translatesAutoresizingMaskIntoConstraints = true
        TerminalTheme.apply(to: view)
        if !context.coordinator.didStart {
            context.coordinator.didStart = true
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            // 默认进入用户 home（GUI 启动的进程 cwd 常为 /，不显式指定会停在根目录）。
            view.startProcess(executable: shell, args: ["-l"], currentDirectory: NSHomeDirectory())
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    /// 视图销毁（关标签 / 换会话）时结束本地 shell。
    /// 必须：SwiftTerm 的 `LocalProcess.deinit` 只取消子进程监视器，**不会杀 shell、不关 PTY fd**；
    /// 不加这一步，每次关闭本地终端标签都会留下一个孤儿 shell + 一个泄漏的 PTY master fd。
    /// `terminate()` 内部幂等（子进程已退出时 `childStopped` 只是置位 + 取消监视器），
    /// 与 `SSHTerminalContainer.dismantleNSView` 同一套收尾模式。
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }

    @MainActor
    final class Coordinator {
        var didStart = false
    }
}
