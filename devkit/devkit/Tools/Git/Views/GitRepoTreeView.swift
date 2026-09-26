//
//  GitRepoTreeView.swift
//  devkit
//
//  Git 仓库集合多级树（手写递归行 + 逐级缩进）。对照 SSHCollectionTree，但支持两种场景：
//   - 主侧栏：点仓库 = 选中并展示；targetFolder 传 nil。
//   - 选择器浏览器：点文件夹 = 选为新建目标（targetFolder 非 nil）；点仓库 = 打开。
//  右键：仓库可 编辑 / 重新定位 / 删除；文件夹可 重命名 / 删除。
//

import SwiftUI

private let kIndent: CGFloat = 14
private let kGutter: CGFloat = 16
private let kIconWidth: CGFloat = 14

struct GitRepoTreeView: View {
    let nodes: [GitCollectionNode]
    var onSelect: (GitRepo) -> Void = { _ in }
    var onEdit: (GitRepo) -> Void = { _ in }
    var onDelete: (GitRepo) -> Void = { _ in }
    var onRelocate: (GitRepo) -> Void = { _ in }
    var onRenameFolder: (GitFolder) -> Void = { _ in }
    var onDeleteFolder: (GitFolder) -> Void = { _ in }
    /// 当前选中的仓库（主侧栏高亮）。
    var selectionRepoID: UUID? = nil
    /// 新建目标文件夹绑定；非 nil 时点击文件夹会写入它（选择器场景）。
    var targetFolder: Binding<UUID?>? = nil
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if nodes.isEmpty {
                Text("还没有登记的仓库")
                    .font(.callout).foregroundStyle(.secondary).padding(10)
            } else {
                ForEach(nodes) { node in
                    GitRepoRow(node: node, depth: 0,
                               onSelect: onSelect, onEdit: onEdit, onDelete: onDelete, onRelocate: onRelocate,
                               onRenameFolder: onRenameFolder, onDeleteFolder: onDeleteFolder,
                               selectionRepoID: selectionRepoID, targetFolder: targetFolder,
                               collapsed: $collapsed)
                }
            }
        }
    }
}

private struct GitRepoRow: View {
    let node: GitCollectionNode
    let depth: Int
    let onSelect: (GitRepo) -> Void
    let onEdit: (GitRepo) -> Void
    let onDelete: (GitRepo) -> Void
    let onRelocate: (GitRepo) -> Void
    let onRenameFolder: (GitFolder) -> Void
    let onDeleteFolder: (GitFolder) -> Void
    let selectionRepoID: UUID?
    let targetFolder: Binding<UUID?>?
    @Binding var collapsed: Set<UUID>

    private var isFolder: Bool { node.isFolder }
    private var children: [GitCollectionNode] { node.children ?? [] }
    private var isExpanded: Bool { !collapsed.contains(node.id) }
    private var isTargetedFolder: Bool { isFolder && targetFolder?.wrappedValue == node.id }
    private var isSelectedRepo: Bool {
        if case .repo(let r) = node.kind { return selectionRepoID == r.id }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            if isFolder && isExpanded {
                ForEach(children) { child in
                    GitRepoRow(node: child, depth: depth + 1,
                               onSelect: onSelect, onEdit: onEdit, onDelete: onDelete, onRelocate: onRelocate,
                               onRenameFolder: onRenameFolder, onDeleteFolder: onDeleteFolder,
                               selectionRepoID: selectionRepoID, targetFolder: targetFolder,
                               collapsed: $collapsed)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * kIndent, height: 1)
            chevron
            Image(systemName: rowSymbol)
                .font(.system(size: 12))
                .foregroundStyle(isFolder ? Color.secondary : (repoValid ? Color.accentColor : .orange))
                .frame(width: kIconWidth)
            if isFolder {
                Text(node.name).font(.system(size: 13))
                    .foregroundStyle(isTargetedFolder ? Color.accentColor : .primary)
                    .lineLimit(1)
            } else if case .repo(let r) = node.kind {
                Text(r.alias).font(.system(size: 13)).lineLimit(1)
                if !r.isValid {
                    Text("路径失效").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(rowHighlight))
        .contentShape(Rectangle())
        .onTapGesture(perform: handleTap)
        .contextMenu { rowMenu }
    }

    private var rowSymbol: String {
        if isFolder { return collapsed.contains(node.id) ? "folder" : "folder.open" }
        return "arrow.triangle.branch"
    }

    private var repoValid: Bool {
        if case .repo(let r) = node.kind { return r.isValid }
        return true
    }

    private var rowHighlight: Color {
        if isSelectedRepo || isTargetedFolder { return Color.accentColor.opacity(0.16) }
        return .clear
    }

    @ViewBuilder
    private var rowMenu: some View {
        switch node.kind {
        case .repo(let r):
            Button("打开") { onSelect(r) }
            Button("编辑 / 重新绑定密钥…") { onEdit(r) }
            Button("重新定位路径…") { onRelocate(r) }
            Divider()
            Button("删除登记", role: .destructive) { onDelete(r) }
        case .folder(let f):
            Button("重命名文件夹…") { onRenameFolder(f) }
            Divider()
            Button("删除文件夹", role: .destructive) { onDeleteFolder(f) }
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if isFolder && !children.isEmpty {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: kGutter, height: 16)
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
        } else {
            Color.clear.frame(width: kGutter, height: 16)
        }
    }

    private func toggle() {
        if collapsed.contains(node.id) { collapsed.remove(node.id) }
        else { collapsed.insert(node.id) }
    }

    private func handleTap() {
        if isFolder {
            // 选择器场景：点文件夹设为新建目标；否则展开/折叠。
            if let targetFolder { targetFolder.wrappedValue = node.id }
            else { toggle() }
        } else if case .repo(let r) = node.kind {
            onSelect(r)
        }
    }
}
