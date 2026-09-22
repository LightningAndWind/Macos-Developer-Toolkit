//
//  SettingsCollectionTree.swift
//  devkit
//
//  设置面板里 HTTP / SSH 分区共用的多级文件夹树。与具体数据模型解耦：
//  外层把 HTTPCollectionStore / SSHProfileStore 的 buildTree() 结果映射成
//  `SettingsTreeNode`，本视图只负责渲染 + 三类动作（删除记录 / 删除文件夹(连同内容) / 移动记录到文件夹）。
//
//  采用手写递归行（逐级固定缩进 + 固定展开槽），与 HTTP/SSH 选择器里的树一致：
//  SwiftUI OutlineGroup 在 ScrollView 内缩进错乱且默认折叠，故不用它。
//

import SwiftUI

private let kSettingsIndent: CGFloat = 14
private let kSettingsGutter: CGFloat = 16
private let kSettingsIconWidth: CGFloat = 14

// MARK: - 视图模型

/// 与 HTTP / SSH 模型无关的树节点。
struct SettingsTreeNode: Identifiable {
    enum Kind {
        /// 文件夹：仅展示名字。
        case folder(name: String)
        /// 记录：标题 + 副标题 + 可选方法徽标（HTTP）或 SF Symbol（SSH）。
        case record(title: String, subtitle: String?, badge: String?, badgeColor: Color?, symbol: String?, symbolColor: Color?)
    }

    let id: UUID
    let kind: Kind
    /// 文件夹的子节点（可为空数组=空文件夹）；记录为 nil。
    let children: [SettingsTreeNode]?

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    /// 供删除确认提示展示的名称（文件夹名 / 记录标题）。
    var displayName: String {
        switch kind {
        case .folder(let name): return name
        case .record(let title, _, _, _, _, _): return title
        }
    }
}

/// 「移动到」子菜单的一个目标文件夹。`id == nil` 表示根目录。
struct SettingsMoveTarget: Identifiable {
    let id: UUID?
    /// 已按层级缩进好的路径标签（如 "    项目 / 后端"）。
    let label: String
}

// MARK: - 树

/// 递归渲染的设置树（不含滚动容器，交由外层包 ScrollView）。
struct SettingsCollectionTreeView: View {
    let nodes: [SettingsTreeNode]
    let moveTargets: [SettingsMoveTarget]
    @Binding var collapsed: Set<UUID>
    let onDeleteRecord: (SettingsTreeNode) -> Void
    let onDeleteFolder: (SettingsTreeNode) -> Void
    let onMoveRecord: (SettingsTreeNode, UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(nodes) { node in
                SettingsTreeRow(node: node,
                                depth: 0,
                                moveTargets: moveTargets,
                                collapsed: $collapsed,
                                onDeleteRecord: onDeleteRecord,
                                onDeleteFolder: onDeleteFolder,
                                onMoveRecord: onMoveRecord)
            }
        }
    }
}

// MARK: - 行

private struct SettingsTreeRow: View {
    let node: SettingsTreeNode
    let depth: Int
    let moveTargets: [SettingsMoveTarget]
    @Binding var collapsed: Set<UUID>
    let onDeleteRecord: (SettingsTreeNode) -> Void
    let onDeleteFolder: (SettingsTreeNode) -> Void
    let onMoveRecord: (SettingsTreeNode, UUID?) -> Void

    @State private var isHovering = false

    private var isFolder: Bool { node.isFolder }
    private var children: [SettingsTreeNode] { node.children ?? [] }
    private var isExpanded: Bool { !collapsed.contains(node.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            if isFolder && isExpanded {
                ForEach(children) { child in
                    SettingsTreeRow(node: child,
                                    depth: depth + 1,
                                    moveTargets: moveTargets,
                                    collapsed: $collapsed,
                                    onDeleteRecord: onDeleteRecord,
                                    onDeleteFolder: onDeleteFolder,
                                    onMoveRecord: onMoveRecord)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(depth) * kSettingsIndent, height: 1)
            chevron
            leadingGlyph
            titleBlock
            Spacer(minLength: 8)
            trailingActions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovering ? Theme.Palette.hoverOverlay : Color.primary.opacity(0.03))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { rowMenu }
    }

    // 文件夹：三角 + folder 图标 + 名字；记录：徽标/符号 + 标题 + 副标题。
    @ViewBuilder
    private var leadingGlyph: some View {
        if isFolder {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: kSettingsIconWidth)
        } else if case .record(_, _, let badge, let badgeColor, let symbol, let symbolColor) = node.kind {
            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(badgeColor ?? .secondary)
                    .frame(minWidth: 32, alignment: .leading)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(symbolColor ?? .secondary)
                    .frame(width: kSettingsIconWidth)
            }
        }
    }

    @ViewBuilder
    private var titleBlock: some View {
        switch node.kind {
        case .folder(let name):
            Text(name)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        case .record(let title, let subtitle, _, _, _, _):
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        Button {
            isFolder ? onDeleteFolder(node) : onDeleteRecord(node)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(isHovering ? Color.red.opacity(0.85) : Color.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0.5)
        .help(isFolder ? "删除该文件夹及其全部内容" : "删除该记录")
    }

    @ViewBuilder
    private var chevron: some View {
        if isFolder && !children.isEmpty {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: kSettingsGutter, height: 16)
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
        } else {
            Color.clear.frame(width: kSettingsGutter, height: 16)
        }
    }

    @ViewBuilder
    private var rowMenu: some View {
        if isFolder {
            Button("删除文件夹（连同内容）", role: .destructive) { onDeleteFolder(node) }
        } else {
            Button("删除", role: .destructive) { onDeleteRecord(node) }
            if !moveTargets.isEmpty {
                Menu("移动到") {
                    // 只有一个根目录目标时（无任何文件夹），子菜单只有「根目录」，仍提供以保持一致。
                    ForEach(moveTargets) { target in
                        Button(target.label) { onMoveRecord(node, target.id) }
                    }
                }
            }
        }
    }

    private func toggle() {
        if collapsed.contains(node.id) { collapsed.remove(node.id) }
        else { collapsed.insert(node.id) }
    }
}
