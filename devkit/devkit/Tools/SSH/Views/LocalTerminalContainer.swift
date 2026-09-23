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
    /// 观察外观：明暗切换时让 SwiftUI 回调 `updateNSView`，据此刷新终端配色。
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        if let font = NSFont(name: "Menlo", size: 12) { view.font = font }
        view.translatesAutoresizingMaskIntoConstraints = true
        TerminalTheme.apply(to: view, colorScheme: colorScheme)
        TerminalTheme.configureScroller(in: view)
        // 回滚缓冲上限：只保留最近 N 行历史，不会无限累积整会话输出。
        view.changeScrollback(Theme.Metrics.terminalScrollbackLines)
        if !context.coordinator.didStart {
            context.coordinator.didStart = true
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            // 默认进入用户 home（GUI 启动的进程 cwd 常为 /，不显式指定会停在根目录）。
            view.startProcess(executable: shell, args: ["-l"], currentDirectory: NSHomeDirectory())
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // 外观（明/暗）切换后重新套用配色：SwiftTerm 会烘焙颜色，需主动刷新。
        TerminalTheme.apply(to: nsView, colorScheme: colorScheme)
    }

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
