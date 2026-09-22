//
//  SSHCollectionTree.swift
//  devkit
//
//  M4：SSH 集合多级文件夹树（手写递归行视图，逐级缩进对齐）。仿 HTTPTreeView。
//  点击连接 = onOpen；点击文件夹 = 选为“新建文件夹”目标父级（targetFolder），展开/折叠走三角。
//

import SwiftUI

private let kIndent: CGFloat = 14
private let kGutter: CGFloat = 16
private let kIconWidth: CGFloat = 14

struct SSHTreeView: View {
    let nodes: [SSHCollectionNode]
    let onOpen: (SSHProfile) -> Void
    var onEdit: (SSHProfile) -> Void = { _ in }
    var onDelete: (SSHProfile) -> Void = { _ in }
    var onEditFolder: (SSHFolder) -> Void = { _ in }
    var onDeleteFolder: (SSHFolder) -> Void = { _ in }
    @Binding var targetFolder: UUID?
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if nodes.isEmpty {
                Text("还没有保存的连接")
                    .font(.callout).foregroundStyle(.secondary).padding(10)
            } else {
                ForEach(nodes) { node in
                    SSHTreeRow(node: node, depth: 0, onOpen: onOpen, onEdit: onEdit, onDelete: onDelete,
                               onEditFolder: onEditFolder, onDeleteFolder: onDeleteFolder,
                               targetFolder: $targetFolder, collapsed: $collapsed)
                }
            }
        }
    }
}

private struct SSHTreeRow: View {
    let node: SSHCollectionNode
    let depth: Int
    let onOpen: (SSHProfile) -> Void
    let onEdit: (SSHProfile) -> Void
    let onDelete: (SSHProfile) -> Void
    let onEditFolder: (SSHFolder) -> Void
    let onDeleteFolder: (SSHFolder) -> Void
    @Binding var targetFolder: UUID?
    @Binding var collapsed: Set<UUID>

    private var isFolder: Bool { node.isFolder }
    private var children: [SSHCollectionNode] { node.children ?? [] }
    private var isExpanded: Bool { !collapsed.contains(node.id) }
    private var isSelectedFolder: Bool { isFolder && targetFolder == node.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            if isFolder && isExpanded {
                ForEach(children) { child in
                    SSHTreeRow(node: child, depth: depth + 1, onOpen: onOpen, onEdit: onEdit, onDelete: onDelete,
                               onEditFolder: onEditFolder, onDeleteFolder: onDeleteFolder,
                               targetFolder: $targetFolder, collapsed: $collapsed)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * kIndent, height: 1)
            chevron
            Image(systemName: isFolder ? "folder" : "terminal")
                .font(.system(size: 12))
                .foregroundStyle(isFolder ? Color.secondary : Color.accentColor)
                .frame(width: kIconWidth)
            if isFolder {
                Text(node.name).font(.system(size: 13))
                    .foregroundStyle(isSelectedFolder ? Color.accentColor : .primary)
                    .lineLimit(1)
            } else if case .profile(let p) = node.kind {
                Text(p.name).font(.system(size: 13)).lineLimit(1)
                Text(p.connectSummary).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(isSelectedFolder ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: handleTap)
        .contextMenu { rowMenu }
    }

    @ViewBuilder
    private var rowMenu: some View {
        switch node.kind {
        case .profile(let p):
            Button("连接") { onOpen(p) }
            Button("编辑…") { onEdit(p) }
            Divider()
            Button("删除", role: .destructive) { onDelete(p) }
        case .folder(let f):
            Button("重命名文件夹…") { onEditFolder(f) }
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
            targetFolder = node.id
        } else if case .profile(let p) = node.kind {
            onOpen(p)
        }
    }
}
