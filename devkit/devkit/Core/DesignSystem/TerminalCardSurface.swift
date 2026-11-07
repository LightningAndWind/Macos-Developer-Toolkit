//
//  TerminalCardSurface.swift
//  devkit
//
//  终端卡片同款面板底（毛玻璃 + 窗口底色 tint + 圆角裁切）的通用修饰器。
//  供终端卡片、记事本面板、右侧竖向工具条共用 —— 同一视觉语言的面板类元素都用它。
//

import SwiftUI

/// 终端卡片 / 记事本面板 / 右侧工具条共用的毛玻璃面板底 + 圆角裁切。
/// 终端视图自身透明，露出此面板；tint 随明暗切换（与终端 ANSI 色板同一外观基准）。
struct TerminalCardSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    panelShape.fill(.ultraThinMaterial)
                    panelShape.fill(Color(nsColor: .windowBackgroundColor)
                        .opacity(colorScheme == .dark ? 0 : 0.2))
                }
            }
            .clipShape(panelShape)
            // 面板类元素的统一悬浮阴影：从毛玻璃底上"浮"起来，与连接横幅等悬浮卡片同一层次语言。
            .shadow(color: Theme.Palette.floatingShadow, radius: 8, y: 2)
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Metrics.terminalCornerRadius, style: .continuous)
    }
}

extension View {
    /// 终端卡片同款面板底（毛玻璃 + 圆角）。
    func terminalCardSurface() -> some View {
        modifier(TerminalCardSurface())
    }
}
