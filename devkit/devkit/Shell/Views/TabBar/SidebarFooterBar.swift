//
//  SidebarFooterBar.swift
//  devkit
//
//  侧栏底部固定操作条：左侧一个设置按钮（齿轮），打开设置面板。
//
//  关键点：本视图位于 TabBarView 的 VStack 中、标签滚动区（ScrollView）之外，
//  因此标签再多、列表滚到底也不会把它滚走；同时它不会侵占 ScrollView 的坐标系
//  （拖拽用的 TabDragSpace 原点仍为滚动区左上角），自绘滚动指示条也只覆盖滚动区。
//

import SwiftUI

struct SidebarFooterBar: View {
    @Environment(AppState.self) private var appState

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 6) {
            settingsButton
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.listPadding)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Metrics.sidebarFooterHeight)
        // 顶部 1pt 分隔线：与上方滚动区划清边界，滚动指示条不会越过它。
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Palette.footerSeparator)
                .frame(height: 1)
        }
    }

    private var settingsButton: some View {
        Button(action: openSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Theme.Palette.hoverOverlay : Color.clear)
                )
                .scaleEffect(isPressed ? 0.94 : 1.0)
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
        .help("设置 (⌘,)")
        .accessibilityLabel("设置")
    }

    private func openSettings() {
        appState.isSettingsPresented = true
    }
}

#Preview {
    VStack(spacing: 0) {
        Color.clear
        SidebarFooterBar()
    }
    .frame(width: Theme.Metrics.sidebarWidth, height: 200)
    .background(.regularMaterial)
    .environment(AppState.shared)
}
