//
//  TerminalTheme.swift
//  devkit
//
//  M4：给 SwiftTerm 终端视图套用与应用协调的配色。
//  SwiftTerm 默认固定黑底白字（`.terminalBackgroundColor`），在浅色外观下与周围的
//  `.ultraThinMaterial` 内容区形成突兀的纯黑块。这里改用语义编辑器底色/文字色，
//  随系统明暗自动切换，远程与本地终端共用同一套。
//

import AppKit
import SwiftTerm

enum TerminalTheme {
    /// 把终端底色/前景/光标切到跟随外观的语义色。
    /// `LocalProcessTerminalView` 继承自 `TerminalView`，故两种终端共用本方法。
    static func apply(to view: TerminalView) {
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        view.caretColor = .textColor
    }
}
