//
//  HTTPCollectionTree.swift
//  devkit
//
//  M5：集合多级文件夹树。手动逐级缩进（固定缩进位 + 固定展开槽），
//  保证不同层级图标左对齐、子级相对父级向右缩进；文件夹默认展开，
//  使内部已保存请求直接可见。替代 OutlineGroup（其在 ScrollView 内缩进错乱、默认折叠）。
//

import SwiftUI

/// 逐级缩进宽度。
private let kTreeIndent: CGFloat = 14
/// 展开三角占位槽宽度（叶子留空，保证各层图标同列对齐）。
private let kTreeGutter: CGFloat = 16
/// 类型图标列宽度。
private let kTreeIconWidth: CGFloat = 14

/// 集合树的一种交互模式。
enum HTTPTreeMode {
    /// 选择目标文件夹（仅文件夹树）；点击文件夹写入选中值。
    case pickFolder(Binding<UUID?>)
    /// 打开已保存请求（文件夹 + 请求树）；点击请求回调；点击文件夹=选为“新建文件夹”的目标父级，展开/折叠走三角。
    case openRequest(onOpen: (HTTPSavedRequest) -> Void, targetFolder: Binding<UUID?>)
}

/// 递归渲染的集合树（不含滚动容器与背景，交由外层包裹）。
struct HTTPTreeView: View {
    let nodes: [HTTPCollectionNode]
    let mode: HTTPTreeMode
    /// 折叠的文件夹 id；默认全展开（集合内为空）。
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(nodes) { node in
                TreeRowView(node: node, depth: 0, mode: mode, collapsed: $collapsed)
            }
        }
    }
}

/// 单行 + 其展开后的子树。整行用扁平 HStack，行与行结构一致 → 图标天然对齐。
private struct TreeRowView: View {
    let node: HTTPCollectionNode
    let depth: Int
    let mode: HTTPTreeMode
    @Binding var collapsed: Set<UUID>

    private var isFolder: Bool { node.isFolder }
    private var children: [HTTPCollectionNode] { node.children ?? [] }
    private var isExpanded: Bool { !collapsed.contains(node.id) }

    private var isSelectedFolder: Bool {
        guard isFolder else { return false }
        switch mode {
        case .pickFolder(let binding): return binding.wrappedValue == node.id
        case .openRequest(_, let target): return target.wrappedValue == node.id
        }
    }

    private var method: String {
        if case .request(let req) = node.kind { return req.request.method }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            if isFolder && isExpanded {
                ForEach(children) { child in
                    TreeRowView(node: child, depth: depth + 1, mode: mode, collapsed: $collapsed)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            // 逐级缩进：depth 越大越向右；根/顶层为 0。
            Color.clear.frame(width: CGFloat(depth) * kTreeIndent, height: 1)
            // 展开槽：有子级才画三角，叶子占空位，图标列因此始终对齐。
            chevron
            Image(systemName: isFolder ? "folder" : "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(isFolder ? Color.secondary : HTTPDisplay.color(forMethod: method))
                .frame(width: kTreeIconWidth)
            label
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(isSelectedFolder ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: handleRowTap)
    }

    @ViewBuilder
    private var chevron: some View {
        if isFolder && !children.isEmpty {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: kTreeGutter, height: 16)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleExpanded)
        } else {
            Color.clear.frame(width: kTreeGutter, height: 16)
        }
    }

    @ViewBuilder
    private var label: some View {
        if isFolder {
            Text(node.name)
                .font(.system(size: 13))
                .foregroundStyle(isSelectedFolder ? Color.accentColor : .primary)
                .lineLimit(1)
        } else {
            // 方法标签与名称拉近：用 minWidth 轻度对齐而非固定 44pt 宽，避免 GET 等短方法后的大空隙。
            Text(method)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(HTTPDisplay.color(forMethod: method))
                .frame(minWidth: 30, alignment: .leading)
            Text(node.name)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private func toggleExpanded() {
        if collapsed.contains(node.id) { collapsed.remove(node.id) }
        else { collapsed.insert(node.id) }
    }

    private func handleRowTap() {
        switch mode {
        case .pickFolder(let binding):
            if isFolder { binding.wrappedValue = node.id }
        case .openRequest(let open, let target):
            if isFolder {
                target.wrappedValue = node.id   // 选为新建文件夹的目标父级（展开/折叠靠三角）
            } else if case .request(let req) = node.kind {
                open(req)
            }
        }
    }
}

/// 仅文件夹的选择树（含虚拟"根"节点）。`selection == nil` 表示选中根。
struct FolderPickerTree: View {
    @Binding var selection: UUID?
    let folders: [HTTPFolder]

    private var nodes: [HTTPCollectionNode] {
        let byParent = Dictionary(grouping: folders, by: { $0.parentID })
        func build(_ f: HTTPFolder) -> HTTPCollectionNode {
            let kids = (byParent[f.id] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map(build)
            return HTTPCollectionNode(id: f.id, kind: .folder(f), children: kids.isEmpty ? nil : kids)
        }
        return (byParent[nil] ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(build)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                rootRow
                HTTPTreeView(nodes: nodes, mode: .pickFolder($selection))
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
    }

    /// 根行：结构与顶层文件夹一致（无缩进、无展开三角、house 图标），保证图标同列。
    private var rootRow: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 0, height: 1)
            Color.clear.frame(width: kTreeGutter, height: 16)
            Image(systemName: "house")
                .font(.system(size: 11))
                .foregroundStyle(selection == nil ? Color.accentColor : Color.secondary)
                .frame(width: kTreeIconWidth)
            Text("根目录").foregroundStyle(selection == nil ? Color.accentColor : .primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(selection == nil ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selection = nil }
    }
}

/// 文件夹 + 请求的浏览树；点击请求触发 `onOpen`，点击文件夹选中为 `targetFolder`。
struct CollectionBrowser: View {
    let nodes: [HTTPCollectionNode]
    let onOpen: (HTTPSavedRequest) -> Void
    @Binding var targetFolder: UUID?

    var body: some View {
        ScrollView {
            Group {
                if nodes.isEmpty {
                    Text("还没有已保存的请求")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HTTPTreeView(nodes: nodes, mode: .openRequest(onOpen: onOpen, targetFolder: $targetFolder))
                }
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
    }
}
