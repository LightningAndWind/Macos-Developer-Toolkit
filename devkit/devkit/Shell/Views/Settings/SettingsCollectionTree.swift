//
//  SettingsCollectionTree.swift
//  devkit
//
//  设置面板里 HTTP / SSH 分区共用的多级文件夹树。与具体数据模型解耦：
//  外层把 HTTPCollectionStore / SSHProfileStore 的 buildTree() 结果映射成
//  `SettingsTreeNode`，本视图只负责渲染 + 四类动作
//  （编辑记录 / 删除记录 / 删除文件夹(连同内容) / 移动记录到文件夹）。
//
//  「编辑记录」与「MCP 访问 / 脱敏开关」都是可选能力：HTTP 记录在自己的标签里编辑、
//  且不经 MCP 暴露，故不传 `onEditRecord` 与 MCP 回调，行内相应不出现铅笔按钮、
//  开关组与右键菜单「编辑…」项。
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
    /// 记录级的 MCP 开关状态；文件夹与不适用 MCP 的记录为 nil。
    var mcp: SettingsMCPToggleValue? = nil

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

/// 记录行内「MCP 访问 / 脱敏」开关的渲染值（与具体模型解耦，回调由外层持有）。
/// `nil` = 该记录不适用（如本地终端记录、HTTP 记录），行内不显示开关。
struct SettingsMCPToggleValue {
    /// 是否由 MCP 提供该记录。
    var accessEnabled: Bool
    /// MCP 输出该记录的数据时是否脱敏（仅访问开启时有意义）。
    var redactionEnabled: Bool
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
    /// 编辑记录；`nil` = 该分区不支持就地编辑（不显示编辑入口）。
    var onEditRecord: ((SettingsTreeNode) -> Void)? = nil
    /// 记录行内「MCP 访问」开关；`nil` = 该分区的记录不带 MCP 开关。
    var onToggleRecordMCP: ((SettingsTreeNode, Bool) -> Void)? = nil
    /// 记录行内「脱敏」开关；`nil` 同上。
    var onToggleRecordRedaction: ((SettingsTreeNode, Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(nodes) { node in
                SettingsTreeRow(node: node,
                                depth: 0,
                                moveTargets: moveTargets,
                                collapsed: $collapsed,
                                onDeleteRecord: onDeleteRecord,
                                onDeleteFolder: onDeleteFolder,
                                onMoveRecord: onMoveRecord,
                                onEditRecord: onEditRecord,
                                onToggleRecordMCP: onToggleRecordMCP,
                                onToggleRecordRedaction: onToggleRecordRedaction)
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
    let onEditRecord: ((SettingsTreeNode) -> Void)?
    let onToggleRecordMCP: ((SettingsTreeNode, Bool) -> Void)?
    let onToggleRecordRedaction: ((SettingsTreeNode, Bool) -> Void)?

    @State private var isHovering = false

    private var isFolder: Bool { node.isFolder }
    private var children: [SettingsTreeNode] { node.children ?? [] }
    private var isExpanded: Bool { !collapsed.contains(node.id) }
    /// 仅记录、且外层提供了编辑回调时才有编辑入口。
    private var canEdit: Bool { !isFolder && onEditRecord != nil }
    /// 仅记录、且节点带 MCP 状态时才显示行内开关。
    private var canToggleMCP: Bool { !isFolder && node.mcp != nil && onToggleRecordMCP != nil }

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
                                    onMoveRecord: onMoveRecord,
                                    onEditRecord: onEditRecord,
                                    onToggleRecordMCP: onToggleRecordMCP,
                                    onToggleRecordRedaction: onToggleRecordRedaction)
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
        // 双击记录 = 编辑（与「编辑…」菜单项同一动作）。
        .onTapGesture(count: 2) { if canEdit { onEditRecord?(node) } }
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
        HStack(spacing: 2) {
            if canToggleMCP, let mcp = node.mcp {
                SettingsMCPToggleGroup(
                    accessEnabled: mcp.accessEnabled,
                    redactionEnabled: mcp.redactionEnabled,
                    onAccess: { onToggleRecordMCP?(node, $0) },
                    onRedaction: { onToggleRecordRedaction?(node, $0) }
                )
            }
            if canEdit {
                iconButton(symbol: "pencil",
                           tint: .secondary,
                           help: L("编辑该记录（名称 / 目录 / 主机等）")) {
                    onEditRecord?(node)
                }
            }
            iconButton(symbol: "trash",
                       tint: isHovering ? Color.red.opacity(0.85) : Color.secondary,
                       help: isFolder ? L("删除该文件夹及其全部内容") : L("删除该记录")) {
                isFolder ? onDeleteFolder(node) : onDeleteRecord(node)
            }
        }
    }

    private func iconButton(symbol: String,
                            tint: Color,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0.5)
        .help(help)
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
            if canEdit {
                Button("编辑…") { onEditRecord?(node) }
                Divider()
            }
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
