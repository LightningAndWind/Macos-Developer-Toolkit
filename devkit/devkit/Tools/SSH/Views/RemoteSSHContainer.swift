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
    /// 观察外观：明暗切换时刷新终端配色。
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        if let font = NSFont(name: "Menlo", size: 12) { view.font = font }
        view.translatesAutoresizingMaskIntoConstraints = true
        TerminalTheme.apply(to: view, colorScheme: colorScheme)
        TerminalTheme.configureScroller(in: view)
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
    }

    /// 依据 profile 组装 ssh 命令行参数。
    /// 私钥认证：`-i <数据目录内绝对路径>`；端口非默认时 `-p`；目标 `user@host`。
    /// 口令 / 密码 / 首次主机指纹确认都由 ssh 在终端内交互提示，无需在此处理。
    private static func sshInvocation(for profile: SSHProfile) -> (String, [String]) {
        var args: [String] = []
        if let fileName = profile.privateKeyFileName,
           let keyURL = SSHKeyStorage.resolvedURL(fileName: fileName) {
            args += ["-i", keyURL.path]
        }
        args += ["-p", String(profile.port), "\(profile.username)@\(profile.host)"]
        return ("/usr/bin/ssh", args)
    }

    @MainActor
    final class Coordinator {
        var didStart = false
    }
}
