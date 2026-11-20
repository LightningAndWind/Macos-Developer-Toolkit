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
    @Environment(\.minimalMode) private var minimalMode

    /// 复制成功瞬时反馈。
    @State private var justCopied = false
    @State private var copyGeneration = 0

    /// 搜索栏输入框焦点：唤出时自动聚焦，便于直接键入。
    @FocusState private var isSearchFieldFocused: Bool

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
        // 简约模式无材质：窗口底已是不透明窗口灰，透出即可。
        .background(minimalMode ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.ultraThinMaterial))
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

            actionButton(L("格式化"), symbol: "list.bullet.indent", disabled: !tool.isValid) { tool.format() }
            actionButton(L("压缩"), symbol: "arrow.down.right.and.arrow.up.left", disabled: !tool.isValid) { tool.minify() }
            sortMenu
            copyButton
            searchButton
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
            help: L("选择缩进宽度")
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

    /// 搜索按钮：开关悬浮查找栏（编辑器内 ⌘F 等效）。开栏时常亮选中底、再点一次收起；
    /// 动作延迟一拍派发，等鼠标抬起完成后再转移第一响应者，避免按压态被截断。
    private var searchButton: some View {
        Button {
            let willOpen = !tool.isSearchVisible
            DispatchQueue.main.async {
                if willOpen { tool.openSearch() } else { tool.closeSearch() }
            }
        } label: {
            Label("搜索", systemImage: "magnifyingglass")
        }
        .buttonStyle(SearchToggleStyle(isActive: tool.isSearchVisible && tool.viewMode == .code))
        .controlSize(.small)
        .disabled(tool.isEmpty)
        .help("搜索（⌘F）")
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

    private var content: some View {
        // zIndex(2)：搜索栏悬浮于内容区右上角，盖过编辑器与树视图。
        ZStack(alignment: .topTrailing) {
            editorContent
            // 搜索只在文本编辑器里定位，故仅悬浮于文本模式；
            // 开关动画走转场令牌，不牵连 NSViewRepresentable 编辑器本身。
            if tool.isSearchVisible, tool.viewMode == .code {
                findBar
                    .transition(Theme.Transitions.dropdown)
                    .zIndex(2)
            }
        }
        .animation(Theme.Motion.content, value: tool.isSearchVisible)
    }

    @ViewBuilder
    private var editorContent: some View {
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

    /// 悬浮查找栏：关键字输入 + 命中计数 + 上/下一个 + 关闭。
    /// 面板质感沿用 DropdownPicker（windowBackgroundColor 底 + 描边 + 投影）。
    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(L("搜索…"), text: $tool.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)
                .focused($isSearchFieldFocused)
                .onSubmit { tool.nextSearchMatch() }
                .onKeyPress(.escape) { tool.closeSearch(); return .handled }
                .onKeyPress(.upArrow) { tool.previousSearchMatch(); return .handled }
                .onKeyPress(.downArrow) { tool.nextSearchMatch(); return .handled }
            searchCount

            Button { tool.previousSearchMatch() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(tool.searchMatchCount == 0)
            .help("查找上一个")
            .pointingHandOnHover()

            Button { tool.nextSearchMatch() } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(tool.searchMatchCount == 0)
            .help("查找下一个")
            .pointingHandOnHover()

            Divider()
                .frame(height: 14)

            Button { tool.closeSearch() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("关闭搜索")
            .pointingHandOnHover()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(minimalMode ? 1 : 0.92))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: Theme.Palette.dragShadow, radius: 10, x: 0, y: 5)
        )
        // 悬停在浮层上时接管光标：铺一层箭头（按钮手型叠在其上，输入框 I 型由 NSTextField 自设），
        // 并标记悬浮态让编辑器让出 I 型光标（浮层压在 NSTextView 跟踪区之上，不标记会被抢设）。
        .onHover { hovering in
            tool.isPointerOverFindBar = hovering
            if hovering { NSCursor.arrow.push() } else { NSCursor.pop() }
        }
        .padding(.trailing, 12)
        .padding(.top, 10)
        .onAppear {
            // 等一拍确保已挂到窗口，再聚焦输入框。
            DispatchQueue.main.async { isSearchFieldFocused = true }
        }
    }

    /// 命中计数：无关键字不占位；无命中提示「无匹配」，否则显示「第 x / y 个匹配」（1 基）。
    @ViewBuilder
    private var searchCount: some View {
        if !tool.searchQuery.isEmpty {
            if tool.searchMatchCount == 0 {
                Text(L("无匹配"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(String(format: L("第 %@ / %@ 个匹配"),
                            String(tool.searchMatchIndex + 1),
                            String(tool.searchMatchCount)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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
                statusLabel(L("等待输入 JSON"), systemImage: "curlybraces", color: .secondary)
            } else if let error = tool.parseError {
                statusLabel(error.displayText, systemImage: "exclamationmark.triangle.fill", color: .red)
            } else {
                statusLabel(L("有效 JSON"), systemImage: "checkmark.circle.fill", color: .green)
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

// MARK: - 搜索开关按钮样式

/// 搜索开关按钮：悬停浮起、按压加深、开栏时常亮选中底，明示「查找栏已打开」。
/// 系统 borderless 样式在毛玻璃工具栏上按压反馈太弱，这里显式分层。
private struct SearchToggleStyle: ButtonStyle {
    /// 查找栏是否处于打开状态（决定常亮选中底）。
    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        SearchToggleLabel(configuration: configuration, isActive: isActive)
    }
}

private struct SearchToggleLabel: View {
    let configuration: ButtonStyle.Configuration
    let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Color.primary.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor)
            )
            .onHover { isHovering = $0 }
            .animation(Theme.Motion.micro, value: isHovering)
            .animation(Theme.Motion.micro, value: isActive)
    }

    /// 底色层级：按压最深 > 开栏选中 > 悬停 > 透明。
    private var fillColor: Color {
        if configuration.isPressed { return Color.primary.opacity(0.14) }
        if isActive { return Theme.Palette.accent.opacity(0.15) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
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
