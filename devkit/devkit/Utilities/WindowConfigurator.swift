//
//  WindowAccessor.swift
//  devkit
//
//  通过 NSViewRepresentable 拿到宿主 NSWindow 并施加配置（Adapter 模式）：
//  把 AppKit 的窗口样式能力适配成 SwiftUI 可声明式调用的形式。
//

import SwiftUI
import AppKit

/// 在视图挂载时配置其宿主窗口。
///
/// 采用「一次性配置 + 幂等」策略：仅当属性发生变化时才写入，避免每帧抖动。
struct WindowConfigurator: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // 延迟到下一帧，确保 view 已入窗、window 可访问。
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            Self.configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            Self.configure(window)
        }
    }

    /// 统一标题栏配置：透明标题栏让内容顶到最上，且点击可穿透到内容控件。
    ///
    /// 这些赋值本身是幂等的，重复执行无副作用，因此无需额外去重标记。
    private static func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // 关闭「拖背景移动」，避免与标签栏点击/拖拽冲突；仍可通过标题栏空白处拖动。
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
    }
}

extension View {
    /// 为视图附加统一标题栏窗口配置能力。
    func unifiedTitleBar() -> some View {
        background(WindowConfigurator())
    }
}
