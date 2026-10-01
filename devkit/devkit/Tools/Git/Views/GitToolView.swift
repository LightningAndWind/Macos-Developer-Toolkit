//
//  GitToolView.swift
//  devkit
//
//  Git 工具根视图。与 SSH 一致：一个标签 = 一个当前仓库（无常驻侧栏，仓库集合走选择器 / "换个仓库"）。
//  未选仓库时展示占位引导去选择器；选中后交给 GitRepoDetailView。流式操作浮出实时控制台；失败以 alert 提示。
//

import SwiftUI

struct GitToolView: View {
    @Bindable var tool: GitTool
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if tool.selectedRepo == nil {
                GitEmptyPrompt(tool: tool)
            } else {
                GitRepoDetailView(tool: tool)
                    .id(tool.selectedRepo?.id)   // 换仓库重建分区状态
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Metrics.terminalContentInset)
        // 选中仓库 / 切换分区是低频事件：即时落盘会话快照，保证重开 App（含开发重编译/强杀）能恢复上次仓库。
        .onChange(of: tool.selectedRepo?.id) { _, _ in appState.saveSession() }
        .onChange(of: tool.section) { _, _ in appState.saveSession() }
        // 提示 toast（成功=绿 / 警告=橙）：顶部浮出，自动消失。
        .overlay(alignment: .top) {
            if let msg = tool.successMessage {
                GitToast(text: msg, color: .green, symbol: "checkmark.circle.fill")
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let msg = tool.warningMessage {
                GitToast(text: msg, color: .orange, symbol: "exclamationmark.triangle.fill")
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.content, value: tool.successMessage)
        .animation(Theme.Motion.content, value: tool.warningMessage)
        // 流式操作实时控制台。
        .sheet(isPresented: $tool.isConsolePresented) {
            GitOutputConsoleView(tool: tool)
        }
        .alert("操作失败", isPresented: Binding(
            get: { tool.errorMessage != nil },
            set: { if !$0 { tool.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { tool.errorMessage = nil }
        } message: {
            Text(tool.errorMessage ?? "")
        }
    }
}

/// 未选仓库时的占位。
private struct GitEmptyPrompt: View {
    @Bindable var tool: GitTool
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("未选择仓库").font(.title3).foregroundStyle(.secondary)
            Button("选择 / 登记仓库") {
                if let id = appState.tabID(for: tool) { appState.gitChooserTabID = id }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 顶部居中的提示胶囊（毛玻璃背景）：成功绿对号 / 警告橙三角，不阻断操作。
private struct GitToast: View {
    let text: String
    let color: Color
    let symbol: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.system(size: 12, weight: .medium))
                // 长报错摘要限两行，避免胶囊横满整个窗口。
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: 520)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(color.opacity(0.35)))
        .shadow(color: Theme.Palette.floatingShadow, radius: 6, y: 2)
    }
}
