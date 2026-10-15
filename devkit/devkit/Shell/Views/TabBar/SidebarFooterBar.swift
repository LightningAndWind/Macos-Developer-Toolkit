//
//  SidebarFooterBar.swift
//  devkit
//
//  侧栏底部固定操作条：左侧为设置按钮（齿轮，打开设置面板）与「防止锁屏」开关（咖啡杯图标）。
//  开关用于长时间任务运行期间保持屏幕常亮、阻止系统锁屏/休眠，避免任务被中断（见 SleepKeeper）。
//
//  关键点：本视图位于 TabBarView 的 VStack 中、标签滚动区（ScrollView）之外，
//  因此标签再多、列表滚到底也不会把它滚走；同时它不会侵占 ScrollView 的坐标系
//  （拖拽用的 TabDragSpace 原点仍为滚动区左上角），自绘滚动指示条也只覆盖滚动区。
//

import SwiftUI

struct SidebarFooterBar: View {
    @Environment(AppState.self) private var appState

    /// 防止锁屏开关（持久化到 UserDefaults，启动时自动恢复）。
    @AppStorage(AppPreferences.preventSleepKey) private var isKeepAwakeOn = false

    @State private var isHovering = false
    @State private var isPressed = false
    @State private var isAwakeHovering = false
    @State private var isAwakePressed = false

    var body: some View {
        HStack(spacing: 6) {
            settingsButton
            keepAwakeToggle
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
        // 启动时按持久化的开关状态恢复断言；开关变化时实时启停。
        .task { syncKeepAwake() }
        .onChange(of: isKeepAwakeOn) { _, _ in syncKeepAwake() }
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

    /// 「防止锁屏」开关：开启时图标高亮填充并带强调色底，与设置按钮同尺寸风格。
    private var keepAwakeToggle: some View {
        Button(action: { isKeepAwakeOn.toggle() }) {
            Image(systemName: isKeepAwakeOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(iconTint)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(backgroundFill)
                )
                .scaleEffect(isAwakePressed ? 0.94 : 1.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isAwakeHovering = $0 }
        .animation(Theme.Motion.micro, value: isAwakeHovering)
        .animation(Theme.Motion.micro, value: isAwakePressed)
        .animation(Theme.Motion.micro, value: isKeepAwakeOn)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isAwakePressed { isAwakePressed = true } }
                .onEnded { _ in isAwakePressed = false }
        )
        .help(isKeepAwakeOn
              ? "防锁屏已开启：点击关闭，恢复系统默认锁屏/休眠"
              : "防止锁屏：保持屏幕常亮，避免长时间任务被中断")
        .accessibilityLabel("防止锁屏")
        .accessibilityValue(isKeepAwakeOn ? "已开启" : "已关闭")
    }

    private var iconTint: Color {
        if isKeepAwakeOn { return .accentColor }
        return isAwakeHovering ? Color.primary : Color.secondary
    }

    private var backgroundFill: Color {
        if isKeepAwakeOn { return Color.accentColor.opacity(0.14) }
        return isAwakeHovering ? Theme.Palette.hoverOverlay : Color.clear
    }

    private func syncKeepAwake() {
        if isKeepAwakeOn {
            SleepKeeper.shared.start()
        } else {
            SleepKeeper.shared.stop()
        }
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
