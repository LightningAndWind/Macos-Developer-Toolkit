//
//  OutsideClickFocusResigner.swift
//  devkit
//
//  行内文本编辑（如标签重命名）期间的「点击框外即退出编辑」支持。
//
//  为什么需要它：macOS 上 AppKit 只有点击到 acceptsFirstResponder 的视图时
//  才会移交第一响应者；点在普通视图（其他标签行、侧栏空白、工具页背景……）上时，
//  正在编辑的 TextField 仍持有焦点，SwiftUI @FocusState 不变，
//  基于「失焦即提交」的退出路径永远不会触发，编辑模式就此卡死。
//
//  因此在编辑期间挂一个本应用的鼠标按下监听：点击落在编辑框外时
//  让第一响应者退位（走既有失焦提交路径），事件本身原样放行，
//  所以点其他标签仍会照常选中它——与 Finder 行内重命名的交互一致。
//

import AppKit

/// 编辑期间监听鼠标按下，点击在编辑框外时令焦点退位。
/// 仅在编辑进行中挂载（`start()` / `stop()`），事件只观察、不拦截、不改写。
@MainActor
final class OutsideClickFocusResigner {
    private var monitor: Any?

    var isActive: Bool { monitor != nil }

    /// 开始监听。重复调用无副作用。
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                Self.resignFocusIfOutside(event: event)
            }
            return event
        }
    }

    /// 停止监听。未挂载时调用无副作用。
    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    deinit {
        // 兜底：正常路径由 stop() 在视图离开层级时清理。
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// 点击落在第一响应者（正在编辑的文本视图）之外时让它退位。
    private static func resignFocusIfOutside(event: NSEvent) {
        // 监听器仅在编辑期间挂载，此刻的 key window 即编辑所在窗口；
        // 点击应用内其他窗口（悬浮面板等）等价于「点去了别处」，同样提交。
        guard let window = NSApp.keyWindow,
              let editor = window.firstResponder as? NSTextView else { return }
        if event.window === window {
            // 点在编辑框内：正常编辑行为（移动光标 / 选择文本），不干预。
            let fieldFrame = editor.convert(editor.bounds, to: nil)
            if fieldFrame.contains(event.locationInWindow) { return }
        }
        // 让焦点退位即可：SwiftUI 的 @FocusState 随之变化，由既有的失焦路径提交。
        window.makeFirstResponder(nil)
    }
}
