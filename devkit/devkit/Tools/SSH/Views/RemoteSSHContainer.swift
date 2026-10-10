//
//  RemoteSSHContainer.swift
//  devkit
//
//  远程 SSH 会话：在 SwiftTerm 的 LocalProcessTerminalView 里直接运行系统 `/usr/bin/ssh`。
//  相比进程内 NIOSSH，外部 ssh 原生支持 RSA（如 AWS 的 boot.pem）、rsa-sha2、OpenSSH/PEM 各类
//  私钥格式、口令与 known_hosts —— 认证与主机校验都交给 OpenSSH 自己，终端里直接可见可交互。
//  视图销毁（关标签 / 断开 / 重连换 id）时 terminate() 结束 ssh 进程。
//

import AppKit
import SwiftUI
import SwiftTerm

struct RemoteSSHContainer: NSViewRepresentable {
    let profile: SSHProfile
    let scrollModel: TerminalScrollModel
    /// 观察外观：明暗切换时刷新终端配色。
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        if let font = NSFont(name: "Menlo", size: 12) { view.font = font }
        view.translatesAutoresizingMaskIntoConstraints = true
        TerminalTheme.apply(to: view, colorScheme: colorScheme)
        TerminalTheme.configureScroller(in: view)
        context.coordinator.attachScrollMonitor(to: view, model: scrollModel)
        if !context.coordinator.didStart {
            context.coordinator.didStart = true
            let (exe, args) = Self.sshInvocation(for: profile)
            view.startProcess(executable: exe, args: args, currentDirectory: NSHomeDirectory())
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // 外观切换后重新套用配色（SwiftTerm 会烘焙颜色，需主动刷新）。
        TerminalTheme.apply(to: nsView, colorScheme: colorScheme)
    }

    /// 视图销毁时结束 ssh 进程（关标签 / 断开 / 重连换身份都会走到这里）。
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
        coordinator.scrollMonitor?.stop()
        coordinator.scrollMonitor = nil
    }

    /// 依据 profile 组装 ssh 命令行参数。
    /// 私钥认证：`-i <数据目录内绝对路径>`；端口非默认时 `-p`；目标 `user@host`。
    /// 记录里配了「默认进入的文件夹」时，追加远程命令 `cd <目录>; exec $SHELL -l`：
    /// 不加这段的话，`ssh host "cmd"` 会在命令结束后直接退出；`-t` 强制分配 pty 保证可交互。
    /// 口令 / 密码 / 首次主机指纹确认都由 ssh 在终端内交互提示，无需在此处理。
    private static func sshInvocation(for profile: SSHProfile) -> (String, [String]) {
        var args: [String] = []
        if let fileName = profile.privateKeyFileName,
           let keyURL = SSHKeyStorage.resolvedURL(fileName: fileName) {
            args += ["-i", keyURL.path]
        }
        args += ["-p", String(profile.port)]
        let target = "\(profile.username)@\(profile.host)"
        if let remoteCommand = profile.sshRemoteCommand {
            args += ["-t", target, remoteCommand]
        } else {
            args += [target]
        }
        return ("/usr/bin/ssh", args)
    }

    @MainActor
    final class Coordinator {
        var didStart = false
        var scrollMonitor: TerminalScrollerMonitor?

        /// scroller 可能尚未创建；未就绪时下一轮主循环重试一次。
        func attachScrollMonitor(to view: NSView, model: TerminalScrollModel) {
            if let m = TerminalTheme.attachScrollMonitor(to: view, model: model) {
                scrollMonitor = m
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.scrollMonitor = TerminalTheme.attachScrollMonitor(to: view, model: model)
            }
        }
    }
}
