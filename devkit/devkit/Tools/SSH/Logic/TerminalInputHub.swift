//
//  TerminalInputHub.swift
//  devkit
//
//  当前终端的输入注入口。三种引擎（本地 shell、私钥外部 ssh、密码 NIOSSH）的终端容器
//  在 makeNSView 时把视图 bind 进来、dismantle 时解绑；记事本「执行」经此把文本
//  写进当前终端 —— LocalProcessTerminalView 会写入自身 PTY，普通 TerminalView 则
//  走 terminalDelegate.send（SSHTerminalContainer 的 Coordinator → client.write），
//  三条路径统一表现为「像键盘键入一样」进入会话。
//

import SwiftTerm

@MainActor
final class TerminalInputHub {
    /// 当前可见的终端视图（weak：视图销毁不悬挂）。
    private weak var view: TerminalView?

    var hasTerminal: Bool { view != nil }

    /// 终端容器创建视图时登记；重复 bind 以最新为准（同一时刻只有一个可见终端）。
    func bind(_ view: TerminalView) {
        self.view = view
    }

    /// 容器 dismantle 时解绑；仅当仍是自己才清空，避免误清新视图的登记。
    func unbind(_ view: TerminalView) {
        if self.view === view { self.view = nil }
    }

    /// 向当前终端发送文本。`pressReturn` 为 true 时补一个回车（\r，等价按下 Enter）。
    /// 返回 false 表示当前没有可用终端（未连接 / 已断开），调用方可提示用户。
    @discardableResult
    func send(_ text: String, pressReturn: Bool = false) -> Bool {
        guard let view else { return false }
        view.send(txt: pressReturn ? text + "\r" : text)
        return true
    }
}
