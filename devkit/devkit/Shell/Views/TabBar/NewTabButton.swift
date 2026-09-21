//
//  NewTabButton.swift
//  devkit
//
//  “+” 新标签按钮：作为标签列表末尾的整行按钮，尺寸与标签行一致，
//  中间一个加号（Chrome 风格）。悬停高亮、按下时轻微缩放，打开 Launcher。
//

import SwiftUI

struct NewTabButton: View {
    @Environment(AppState.self) private var appState

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: openLauncher) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Metrics.tabRowHeight)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.tabCornerRadius)
                        .fill(isHovering ? Theme.Palette.hoverOverlay : Theme.Palette.tabIdle)
                )
                .scaleEffect(isPressed ? 0.96 : 1.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.micro, value: isHovering)
        .animation(Theme.Motion.micro, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isPressed { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
        .help("新建标签 (⌘T)")
    }

    private func openLauncher() {
        withAnimation(Theme.Motion.content) {
            appState.tabManager.isLauncherPresented = true
            appState.tabManager.selectedTabID = nil
        }
    }
}
