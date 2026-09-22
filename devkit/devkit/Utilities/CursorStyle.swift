//
//  CursorStyle.swift
//  devkit
//
//  光标辅助：给可点击控件在悬停时切换为手指形状（macOS 默认是箭头）。
//  push/pop 成对，避免污染相邻控件的光标状态。
//

import AppKit
import SwiftUI

extension View {
    /// 鼠标悬停期间显示手指光标，离开后恢复。用于按钮、菜单、可点击行等。
    func pointingHandOnHover() -> some View {
        onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
