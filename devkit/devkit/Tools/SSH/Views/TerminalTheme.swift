//
//  TerminalTheme.swift
//  devkit
//
//  给 SwiftTerm 终端视图套用与应用协调的「毛玻璃」配色 + 明暗自适应的 ANSI 16 色调色板。
//
//  两件事：
//  1) 背景/前景：终端逐格用 `nativeBackgroundColor` 填充默认底，视图 layer-backed 但非 opaque；
//     把该底色设为**半透明**语义「窗口」色，容器后方 SSHToolView 的 `.ultraThinMaterial`
//     （叠在窗口 `hudWindow` behind-window 模糊之上）即可透出，形成与应用一致的毛玻璃。
//  2) ANSI 16 色：shell 提示符 / `ls` 等用绿色、紫色等 ANSI 色。SwiftTerm 默认只有一套固定调色板，
//     在浅色背景下深色系 ANSI 色看不清、深色背景下亮色系 ANSI 色看不清。这里按 colorScheme 安装
//     **两套各自可读**的 16 色板（浅色模式偏深、深色模式偏亮），经 `installColors` 生效并重绘。
//
//  ⚠️ 外观解析坑：App 通过 `NSApp.appearance` override 手动切换深浅色。而 SwiftTerm 的
//  `setupOptions()` 会 `layer.backgroundColor = nativeBackgroundColor.cgColor`、`nativeXxxColor`
//  setter 会 `getTerminalColor()`，都在**赋值当下**按 `NSAppearance.current` 把动态语义色烘焙成静态值，
//  那一刻的外观未必等于终端该呈现的外观 → 深浅色反相、发灰、字与底同色。
//  对策：由容器把 SwiftUI 的 `colorScheme`（App 强制模式的权威来源）传入，据此构造明确 `NSAppearance`，
//  在其下把动态语义色解析成**具体 RGB** 再交给 SwiftTerm。外观切换时容器 `updateNSView` 会带新值再 apply。
//  远程与本地终端共用同一套。
//

import AppKit
import SwiftUI
import SwiftTerm

enum TerminalTheme {
    /// 终端视图自身底色保持全透明：毛玻璃 tint 统一由外层终端面板（SSHToolView 卡片背景）着色，
    /// 这样内边距环与终端区是同一层底色，不会因终端自带 tint 而出现“两层边框”。
    /// 前景/光标/选区/ANSI 色板仍按 `colorScheme` 解析为具体值（避免外观反相）。

    /// 把终端底色/前景/光标/ANSI 调色板切到与 `colorScheme` 匹配的具体值。
    /// `LocalProcessTerminalView` 继承自 `TerminalView`，故两种终端共用本方法。
    static func apply(to view: TerminalView, colorScheme: ColorScheme) {
        // 由 colorScheme 明确构造外观，杜绝「按当前/系统外观误解析」导致的反相。
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            ?? NSAppearance(named: .aqua)!

        let foreground = resolve(.labelColor, in: appearance)
        let selectedBackground = resolve(.selectedTextBackgroundColor, in: appearance)
        let opaqueWindow = resolve(.windowBackgroundColor, in: appearance)

        // 终端自身透明，让后方面板材质 + tint 透出（与内边距环同色）。
        view.nativeBackgroundColor = .clear
        view.nativeForegroundColor = foreground
        view.caretColor = foreground
        // 块状光标覆盖字符时，其上的文字用「不透明」窗口底色，保证与光标底色对比清晰。
        view.caretTextColor = opaqueWindow
        view.selectedTextBackgroundColor = selectedBackground
        // layer 底也置透明，与 nativeBackgroundColor 一致。
        view.layer?.backgroundColor = NSColor.clear.cgColor
        // 安装随明暗切换的 ANSI 16 色板（内部会清色板缓存并触发全量重绘）。
        view.installColors(ansiPalette(for: colorScheme))
        view.needsDisplay = true
    }

    /// 隐藏终端右侧滚动条：SwiftTerm 内部用的是独立 `NSScroller`（非 NSScrollView 托管），
    /// 其 `legacy` 样式会常驻一条灰色轨道背景，贴在毛玻璃上很突兀；强改 `overlay` 又因无滚动视图
    /// 托管导致滑块不出现、轨道残留。故直接隐藏整个滚动条——终端仍可用触控板/滚轮/键盘滚动，
    /// 隐藏后腾出的右侧区域露出均匀的面板材质，不再有一条突兀背景。
    /// `setupScroller()` 仅在 init 调一次，故隐藏一次即持久。递归查找以防层级变化。
    static func configureScroller(in view: NSView) {
        for sub in view.subviews {
            if let scroller = sub as? NSScroller {
                scroller.isHidden = true
            } else {
                configureScroller(in: sub)
            }
        }
    }

    /// 在指定 `NSAppearance` 下，把 AppKit 动态语义色解析成具体的 deviceRGB 颜色。
    private static func resolve(_ dynamicColor: NSColor, in appearance: NSAppearance) -> NSColor {
        var resolved = dynamicColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = dynamicColor.usingColorSpace(.deviceRGB) ?? dynamicColor
        }
        return resolved
    }

    // MARK: - ANSI 16 色调色板

    /// 按外观返回可读的 16 色板：索引 0-15 = 黑 红 绿 黄 蓝 品红 青 白 + 各自高亮变体。
    /// 浅色背景用整体偏深的一套（绿/品红/黄等压暗，避免浅底看不清）；深色背景用整体偏亮的一套。
    private static func ansiPalette(for scheme: ColorScheme) -> [SwiftTerm.Color] {
        scheme == .dark ? darkPalette : lightPalette
    }

    /// 浅色背景：正常色偏深、饱和，保证在浅灰/白底上清晰。
    private static let lightPalette: [SwiftTerm.Color] = [
        hex(0x2e3436), hex(0xa40000), hex(0x0a7a2f), hex(0x8a5a00),   // 黑 红 绿 黄
        hex(0x0031a8), hex(0x8b1a8b), hex(0x00707a), hex(0xcfcfcf),   // 蓝 品红 青 白
        hex(0x555753), hex(0xc01c28), hex(0x2f9e45), hex(0xa86f00),   // 高亮黑 红 绿 黄
        hex(0x3465a4), hex(0xa347ba), hex(0x008c99), hex(0xffffff),   // 高亮蓝 品红 青 白
    ]

    /// 深色背景：正常色偏亮，保证在暗底上清晰（尤其绿、品红）。
    private static let darkPalette: [SwiftTerm.Color] = [
        hex(0x4e4e4e), hex(0xff5f5f), hex(0x4ee06a), hex(0xf2d36b),   // 黑 红 绿 黄
        hex(0x6c9bff), hex(0xe08cff), hex(0x5ad4d4), hex(0xe5e5e5),   // 蓝 品红 青 白
        hex(0x6a6a6a), hex(0xff8080), hex(0x7fff9e), hex(0xffe599),   // 高亮黑 红 绿 黄
        hex(0x9dc0ff), hex(0xf0b3ff), hex(0x8cffef), hex(0xffffff),   // 高亮蓝 品红 青 白
    ]

    /// 0xRRGGBB → SwiftTerm `Color`（8bit 分量按 xterm 惯例放大到 16bit：v * 257）。
    private static func hex(_ value: UInt32) -> SwiftTerm.Color {
        let r = UInt16(((value >> 16) & 0xff) * 257)
        let g = UInt16(((value >> 8) & 0xff) * 257)
        let b = UInt16((value & 0xff) * 257)
        return SwiftTerm.Color(red: r, green: g, blue: b)
    }
}
