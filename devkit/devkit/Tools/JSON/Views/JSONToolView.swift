//
//  JSONToolView.swift
//  devkit
//
//  M3：JSON 工具根视图 —— 顶部工具栏（视图切换 / 缩进 / 格式化 / 压缩 / 排序 / 复制）
//  + 内容区（文本编辑器 / 只读树）+ 底部状态栏（校验结果与统计）。
//

import AppKit
import SwiftUI

struct JSONToolView: View {
    @Bindable var tool: JSONTool
    @Environment(AppState.self) private var appState
    @Environment(\.activeToolTab) private var isActiveTab

    /// 复制成功瞬时反馈。
    @State private var justCopied = false
    @State private var copyGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            // zIndex(1)：缩进下拉面板要溢出工具栏下沿，须盖过其后渲染的内容区。
            toolbar
                .zIndex(1)
            Divider()
            content
            Divider()
            statusBar
        }
        .background(.ultraThinMaterial)
        // 编辑内容后防抖落盘，保证直接退出 App 也能还原标签内容。
        .onChange(of: tool.text) { _, _ in appState.scheduleSessionSave() }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            CapsuleSegmentedPicker(options: JSONViewMode.allCases.map { ($0, $0.label) },
                                   selection: $tool.viewMode)

            indentMenu

            Spacer()

            actionButton("格式化", symbol: "list.bullet.indent", disabled: !tool.isValid) { tool.format() }
            actionButton("压缩", symbol: "arrow.down.right.and.arrow.up.left", disabled: !tool.isValid) { tool.minify() }
            sortMenu
            copyButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 复制按钮：点击后短暂显示“复制成功”。
    private var copyButton: some View {
        Button { copyAll() } label: {
            Label(justCopied ? "复制成功" : "复制",
                  systemImage: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(justCopied ? Color.green : Color.primary)
        .disabled(tool.isEmpty)
        .pointingHandOnHover()
    }

    private var indentMenu: some View {
        DropdownPicker(
            options: JSONIndent.allCases.map { option in
                DropdownOption(title: option.label,
                               checked: tool.indent == option,
                               action: { tool.indent = option })
            },
            help: "选择缩进宽度"
        ) { _ in
            Label(String(format: L("缩进 %@"), String(tool.indent.label)), systemImage: "shift")
                .font(.system(size: 12))
        }
        .pointingHandOnHover()
    }

    private var sortMenu: some View {
        Menu {
            Button("升序（递归）") { tool.sortKeys(ascending: true, recursive: true) }
            Button("降序（递归）") { tool.sortKeys(ascending: false, recursive: true) }
            Divider()
            Button("升序（仅顶层）") { tool.sortKeys(ascending: true, recursive: false) }
            Button("降序（仅顶层）") { tool.sortKeys(ascending: false, recursive: false) }
        } label: {
            Label("排序", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!tool.isValid)
        .pointingHandOnHover()
    }

    private func actionButton(_ title: String, symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(disabled)
        .pointingHandOnHover()
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if tool.viewMode == .code {
            JSONCodeTextView(tool: tool, isActive: isActiveTab)
                // 锁定到内容区并裁切：防止 NSScrollView 用 documentView 的巨大固有尺寸
                // 撑破 VStack 布局，导致行号标尺分隔线溢出到工具栏。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            if let value = tool.parsedValue {
                JSONTreeView(value: value)
            } else {
                treeUnavailable
            }
        }
    }

    private var treeUnavailable: some View {
        ContentUnavailableView {
            Label("无法构建树", systemImage: "list.bullet.indent.curved")
        } description: {
            Text(L(tool.parseError?.displayText ?? "请输入合法的 JSON 后再查看树形视图。"))
        }
    }

    // MARK: - 状态栏

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 14) {
            if tool.isEmpty {
                statusLabel("等待输入 JSON", systemImage: "curlybraces", color: .secondary)
            } else if let error = tool.parseError {
                statusLabel(error.displayText, systemImage: "exclamationmark.triangle.fill", color: .red)
            } else {
                statusLabel("有效 JSON", systemImage: "checkmark.circle.fill", color: .green)
                if let value = tool.parsedValue {
                    let stats = value.stats
                    Text(String(format: L("节点 %@"), String(stats.nodeCount))).foregroundStyle(.secondary)
                    Text(String(format: L("深度 %@"), String(stats.maxDepth))).foregroundStyle(.secondary)
                    Text(typeBreakdown(stats)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(String(format: L("%@ 字符 · %@ 行"), String(tool.characterCount), String(tool.lineCount)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func statusLabel(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func typeBreakdown(_ stats: JSONValue.Stats) -> String {
        var parts: [String] = []
        if stats.objectCount > 0 { parts.append(String(format: L("对象 %@"), String(stats.objectCount))) }
        if stats.arrayCount > 0 { parts.append(String(format: L("数组 %@"), String(stats.arrayCount))) }
        if stats.stringCount > 0 { parts.append(String(format: L("字符串 %@"), String(stats.stringCount))) }
        if stats.numberCount > 0 { parts.append(String(format: L("数字 %@"), String(stats.numberCount))) }
        if stats.boolCount > 0 { parts.append(String(format: L("布尔 %@"), String(stats.boolCount))) }
        if stats.nullCount > 0 { parts.append(String(format: L("空 %@"), String(stats.nullCount))) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 行为

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tool.text, forType: .string)
        flashCopied()
    }

    /// 复制成功后短暂展示提示，约 1.4s 后自动复原。
    private func flashCopied() {
        copyGeneration += 1
        let generation = copyGeneration
        justCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if generation == copyGeneration { justCopied = false }
        }
    }
}

// MARK: - 自定义分段切换器（无系统分隔线）

/// 胶囊式分段选择：选中项用浮起胶囊标识，段与段之间无竖分隔线，
/// 避免系统 `Picker(.segmented)` 在选中段与未选段之间画出亮竖线。
private struct CapsuleSegmentedPicker<T: Hashable>: View {
    let options: [(value: T, title: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = selection == option.value
                Text(option.title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                                .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = option.value }
                    .pointingHandOnHover()
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }
}
