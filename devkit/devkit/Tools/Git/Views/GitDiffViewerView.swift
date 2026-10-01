//
//  GitDiffViewerView.swift
//  devkit
//
//  工作区「文件检查器」：点击变更文件后在右侧展示其内容差异（参考 IDE 的 Diff 视图）。
//  - 普通文件：unified diff，逐行渲染——新增绿底、删除红底、修改=删+增相邻成对、@@ 块头灰底。
//  - 冲突文件：展示带标记的工作区内容，冲突块分组着色，块头提供「保留我方 / 保留对方」按钮；
//    工具栏另有整文件级「采用我方 / 采用对方 / 标记已解决」。
//

import SwiftUI
import AppKit

// MARK: - 渲染内容模型

/// 检查器主体要渲染的内容（由工具状态推导）。
enum GitDiffContent {
    case loading
    case conflict(lines: [String], blocks: [GitConflictBlock])
    case diff([GitDiffLine])
    case note(String)
}

// MARK: - 检查器（工具栏 + 内容）

struct GitFileInspectorView: View {
    @Bindable var tool: GitTool

    /// 当前选中文件的状态条目（动作刷新后可能变化，如冲突解决后变为已暂存）。
    private var entry: GitFileEntry? {
        guard let path = tool.selectedFilePath else { return nil }
        return tool.status.entries.first { $0.path == path }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.5)))
    }

    // MARK: 头部：路径 + 统计 + 动作按钮

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    tool.clearFileSelection()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("关闭预览")

                Text(entry?.path ?? tool.selectedFilePath ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)

                if let entry {
                    Text(entry.badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(entry.conflicted ? Color.red : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill((entry.conflicted ? Color.red : Color.secondary).opacity(0.12)))
                }

                Spacer()

                if let diff = tool.fileDiff, case .unified = diff, entry?.conflicted != true {
                    Text("+\(diff.addedCount)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                    Text("-\(diff.removedCount)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                }
                if let blocks = optionalConflictCount {
                    chip("\(blocks) 处冲突", .red)
                }
            }

            HStack(spacing: 8) {
                switch rowKind {
                case .conflict:
                    Button("采用我方") { resolveWholeFile(.ours) }
                    Button("采用对方") { resolveWholeFile(.theirs) }
                    Button("标记已解决") { Task { await tool.markResolved(file: entry?.path ?? "") } }
                case .staged:
                    Button("取消暂存") { run { await tool.unstage(paths: [entry?.path ?? ""]) } }
                case .unstaged:
                    Button("暂存") { run { await tool.stage(paths: [entry?.path ?? ""]) } }
                    Button("丢弃") { run { await tool.discard(paths: [entry?.path ?? ""]) } }
                        .foregroundStyle(.red)
                case .untracked:
                    Button("暂存") { run { await tool.stage(paths: [entry?.path ?? ""]) } }
                case .none:
                    EmptyView()
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(tool.isBusy || entry == nil)
        }
        .padding(8)
    }

    /// 与列表行一致的行语义（决定工具栏按钮组合）。
    private var rowKind: GitChangesSection.RowKind? {
        guard let entry else { return nil }
        if entry.conflicted { return .conflict }
        if entry.untracked { return .untracked }
        if entry.isStaged { return .staged }
        return .unstaged
    }

    private var optionalConflictCount: Int? {
        entry?.conflicted == true ? tool.conflictBlocks.count : nil
    }

    @ViewBuilder
    private var content: some View {
        let currentEntry = entry
        switch derivedContent(currentEntry) {
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("读取差异…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .conflict(let lines, let blocks):
            GitConflictContentView(tool: tool, entry: currentEntry, lines: lines, blocks: blocks)
        case .diff(let lines):
            GitUnifiedDiffView(lines: lines)
        case .note(let text):
            Label(text, systemImage: "doc")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func derivedContent(_ entry: GitFileEntry?) -> GitDiffContent {
        if tool.isDiffLoading { return .loading }
        guard let entry else { return .note("文件已不在变更列表") }
        if entry.conflicted {
            // 冲突文件以工作区带标记内容为准，而非 diff。
            if !tool.conflictLines.isEmpty || !tool.conflictBlocks.isEmpty {
                return .conflict(lines: tool.conflictLines, blocks: tool.conflictBlocks)
            }
            return .note("未能读取冲突内容")
        }
        if !entry.untracked && !entry.isStaged && !entry.hasUnstaged { return .note("无内容差异") }
        switch tool.fileDiff {
        case .unified(_, _, let lines) where !lines.isEmpty:
            return .diff(lines)
        case .unified:
            return .note(entry.badge == "删除" ? "文件已删除（无内容展示）" : "无内容差异")
        case .unavailable(let reason):
            return .note(reason)
        case nil:
            return .note("未加载差异")
        }
    }

    // MARK: 动作

    private func resolveWholeFile(_ side: GitRepository.ConflictSide) {
        guard let path = entry?.path else { return }
        run { await tool.resolveConflict(file: path, side: side) }
    }

    /// 执行动作后刷新选中文件预览（perform 内部已 refreshAll）。
    private func run(_ action: @escaping () async -> Void) {
        Task {
            await action()
            await tool.reloadSelectedFile()
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

// MARK: - unified diff 渲染

struct GitUnifiedDiffView: View {
    let lines: [GitDiffLine]

    var body: some View {
        // 双向 ScrollView 里有两个坑：① 行宽会退化成各自文本宽度（maxWidth 在无宽度提案下失效）；
        // ② 内容比视口小时会被整体居中。两者叠加 = 差异块缩成浮在面板正中的一小条。
        // 解法：行宽显式给出 max(视口宽, 最长行宽)（短行铺满、长行撑开内容以保留横向滚动），
        // 内容高度兜底到视口高 + 锚定左上，消除居中。
        GeometryReader { geo in
            let width = max(geo.size.width, lines.map { diffRowWidth($0.text, mono: 11) }.max() ?? 0)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        GitDiffLineRow(
                            line: line,
                            style: style(for: line, in: lines),
                            mono: 11,
                            width: width)
                    }
                }
                .padding(.vertical, 4)
                .frame(minHeight: geo.size.height, alignment: .topLeading)
            }
            .defaultScrollAnchor(.topLeading)
            .scrollIndicators(.never)
            .scrollIndicatorBar()
        }
    }

    /// 相邻的「删+增」视为修改对，用黄色区分开于纯新增/纯删除（参考 IDE 的 Modified 着色）。
    private func style(for line: GitDiffLine, in lines: [GitDiffLine]) -> GitDiffRowStyle {
        switch line.kind {
        case .added:
            let idx = line.id
            if idx > 0, idx < lines.count, lines[idx - 1].kind == .removed { return .changeRight }
            return .add
        case .removed:
            let idx = line.id
            if idx + 1 < lines.count, lines[idx + 1].kind == .added { return .changeLeft }
            return .delete
        case .hunkHeader:
            return .hunk
        case .context, .meta:
            return .context
        }
    }
}

enum GitDiffRowStyle {
    case context, add, delete, changeLeft, changeRight, hunk, conflictLeft, conflictRight, marker

    var background: Color {
        switch self {
        case .context: return .clear
        case .add: return Color.green.opacity(0.14)
        case .delete: return Color.red.opacity(0.14)
        case .changeLeft, .changeRight: return Color.yellow.opacity(0.16)
        case .hunk: return Color.secondary.opacity(0.10)
        case .conflictLeft: return Color.orange.opacity(0.15)
        case .conflictRight: return Color.blue.opacity(0.15)
        case .marker: return .clear
        }
    }
    var gutterText: String {
        switch self {
        case .add: return "+"
        case .delete: return "-"
        case .changeLeft: return "-"
        case .changeRight: return "+"
        case .conflictLeft: return "‹"
        case .conflictRight: return "›"
        case .marker: return "!"
        case .context, .hunk: return " "
        }
    }
    var gutterColor: Color {
        switch self {
        case .add, .changeRight: return .green
        case .delete, .changeLeft: return .red
        case .conflictLeft: return .orange
        case .conflictRight: return .blue
        case .marker: return .red
        case .context, .hunk: return .clear
        }
    }
}

/// 单行内容宽度：两侧行号列（40+40）+ 前缀列（16）+ 文本 + 尾部留白（12）。
/// 必须与 `GitDiffLineRow` 的排版一致；多留 2pt 吸收字体测量的舍入误差，避免末字被裁。
func diffRowWidth(_ text: String, mono: CGFloat) -> CGFloat {
    let font = NSFont.monospacedSystemFont(ofSize: mono, weight: .regular)
    let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
    return 40 + 40 + 16 + textWidth.rounded(.up) + 12 + 2
}

/// 单行：左右行号 + 前缀符 + 内容（横向滚动不折行，等宽字体）。
/// `width` 由容器显式给出（见 `GitUnifiedDiffView`）：双向 ScrollView 里 `maxWidth: .infinity`
/// 拿不到宽度提案，行底色只会裹住文字，面板再宽也填不满。
struct GitDiffLineRow: View {
    let line: GitDiffLine
    let style: GitDiffRowStyle
    let mono: CGFloat
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldLine.map(String.init) ?? "")
                .frame(width: 40, alignment: .trailing)
            Text(line.newLine.map(String.init) ?? "")
                .frame(width: 40, alignment: .trailing)
            Text(style.gutterText)
                .frame(width: 16, alignment: .center)
                .foregroundStyle(style.gutterColor)
            Text(line.text.isEmpty ? " " : line.text)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .font(.system(size: mono, design: .monospaced))
        .foregroundStyle(style == .hunk ? Color.secondary : Color.primary)
        .padding(.trailing, 12)
        .frame(width: width, alignment: .leading)
        .background(style.background)
    }
}

// MARK: - 冲突内容渲染（带标记 + 分块解决）

struct GitConflictContentView: View {
    @Bindable var tool: GitTool
    let entry: GitFileEntry?
    let lines: [String]
    let blocks: [GitConflictBlock]

    var body: some View {
        // 与 GitUnifiedDiffView 同因同解：行宽显式给出，内容锚定左上、不被居中。
        GeometryReader { geo in
            let width = max(geo.size.width, lines.map { diffRowWidth($0, mono: 11) }.max() ?? 0)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, text in
                        if let blockIndex = blockStartIndex(idx) {
                            blockHeader(index: blockIndex, width: width)
                        }
                        GitDiffLineRow(
                            line: GitDiffLine(id: idx, kind: .context, text: text, oldLine: idx + 1, newLine: idx + 1),
                            style: style(forLine: idx),
                            mono: 11,
                            width: width)
                    }
                }
                .padding(.vertical, 4)
                .frame(minHeight: geo.size.height, alignment: .topLeading)
            }
            .defaultScrollAnchor(.topLeading)
            .scrollIndicators(.never)
            .scrollIndicatorBar()
        }
    }

    /// 行所属冲突块及边（左段=我方，右段=对方）。
    private func sideOf(line idx: Int) -> (block: GitConflictBlock, isLeft: Bool)? {
        for block in blocks {
            if idx >= block.startLine && idx < block.endLine {
                return (block, idx < block.dividerLine)
            }
        }
        return nil
    }

    private func style(forLine idx: Int) -> GitDiffRowStyle {
        guard let (block, isLeft) = sideOf(line: idx) else { return .context }
        if idx == block.startLine || idx == block.dividerLine || idx == block.endLine - 1 {
            return .marker
        }
        return isLeft ? .conflictLeft : .conflictRight
    }

    /// 冲突块起始行前插入操作条（每个块只在其 startLine 出现一次）。
    private func blockStartIndex(_ idx: Int) -> Int? {
        guard let pos = blocks.firstIndex(where: { $0.startLine == idx }) else { return nil }
        return pos
    }

    private func blockHeader(index: Int, width: CGFloat) -> some View {
        let block = blocks[index]
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.system(size: 10))
            Text("冲突 \(index + 1)/\(blocks.count) · \(block.leftLabel) ⇄ \(block.rightLabel)")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("保留我方") { resolve(blockIndex: index, keepOurSide: true) }
            Button("保留对方") { resolve(blockIndex: index, keepOurSide: false) }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(width: width, alignment: .leading)
        .background(Color.red.opacity(0.06))
    }

    private func resolve(blockIndex: Int, keepOurSide: Bool) {
        guard let entry else { return }
        Task {
            await tool.resolveConflictBlock(entry: entry, blockIndex: blockIndex, keepOurSide: keepOurSide)
            await tool.reloadSelectedFile()
        }
    }
}
