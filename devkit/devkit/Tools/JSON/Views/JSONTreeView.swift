//
//  JSONTreeView.swift
//  devkit
//
//  M3 JSON 工具：只读树形视图。文本为唯一数据源，树只负责折叠/展开浏览、路径面包屑定位与
//  复制子树。沿用 HTTPCollectionTree 的"手写递归行视图 + 逐级缩进"模式（项目规范不用 OutlineGroup）。
//

import AppKit
import SwiftUI

/// JSON 只读浏览树。
struct JSONTreeView: View {
    let value: JSONValue

    @State private var collapsed: Set<String> = []
    @State private var selectionPath: String = "$"

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            ScrollView([.vertical]) {
                VStack(alignment: .leading, spacing: 2) {
                    JSONTreeRowView(value: value, keyLabel: nil, path: "$", depth: 0,
                                    collapsed: $collapsed, selectionPath: $selectionPath)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 顶部面包屑：显示当前选中节点路径。
    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.forward.to.point.capsulepath")
                .foregroundStyle(.secondary)
            Text(selectionPath)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 单行 + 其展开后的子树。整行扁平 HStack，行结构一致 → 图标天然对齐。
private struct JSONTreeRowView: View {
    let value: JSONValue
    let keyLabel: String?
    let path: String
    let depth: Int
    @Binding var collapsed: Set<String>
    @Binding var selectionPath: String

    private var isContainer: Bool { value.isContainer }
    private var isExpanded: Bool { !collapsed.contains(path) }
    private var isSelected: Bool { selectionPath == path }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            if isContainer && isExpanded {
                ForEach(childRows) { child in
                    JSONTreeRowView(value: child.value, keyLabel: child.key, path: child.path,
                                    depth: depth + 1, collapsed: $collapsed, selectionPath: $selectionPath)
                }
            }
        }
    }

    /// 子行描述：对象用键名，数组用下标；生成子路径。
    private var childRows: [ChildDescriptor] {
        switch value {
        case .object(let members):
            return members.map { JSONMemberWrapper($0).descriptor(parentPath: path) }
        case .array(let values):
            return values.enumerated().map { (index, val) in
                ChildDescriptor(value: val, key: nil, path: "\(path)[\(index)]")
            }
        default:
            return []
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * Theme.Metrics.jsonTreeIndent, height: 1)
            chevron
            Image(systemName: typeSymbol)
                .font(.system(size: 11))
                .foregroundStyle(typeColor)
                .frame(width: Theme.Metrics.jsonTreeIconWidth)
            label
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selectionPath = path }
        .pointingHandOnHover()
        .contextMenu {
            Button {
                copySubtree()
            } label: {
                Label("复制该节点", systemImage: "doc.on.doc")
            }
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if isContainer, value.childCount > 0 {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: Theme.Metrics.jsonTreeGutter, height: 16)
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
                .pointingHandOnHover()
        } else {
            Color.clear.frame(width: Theme.Metrics.jsonTreeGutter, height: 16)
        }
    }

    @ViewBuilder
    private var label: some View {
        if let keyLabel {
            Text(keyLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.jsonKey)
            Text(":").foregroundStyle(Theme.Palette.jsonPunctuation)
        }
        if isContainer {
            Text(scalarSummary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            Text(scalarSummary)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var scalarSummary: String { value.scalarDisplay }

    private var typeSymbol: String {
        switch value {
        case .object: return "curlybraces"
        case .array:  return "square.brackets"
        case .string: return "textformat"
        case .number: return "number"
        case .bool:   return "t"
        case .null:   return "circle.dashed"
        }
    }

    private var typeColor: Color {
        switch value {
        case .object, .array: return .secondary
        case .string: return Theme.Palette.jsonString
        case .number: return Theme.Palette.jsonNumber
        case .bool, .null: return Theme.Palette.jsonLiteral
        }
    }

    private var valueColor: Color {
        switch value {
        case .string: return Theme.Palette.jsonString
        case .number: return Theme.Palette.jsonNumber
        case .bool, .null: return Theme.Palette.jsonLiteral
        default: return .primary
        }
    }

    private func toggle() {
        if collapsed.contains(path) { collapsed.remove(path) }
        else { collapsed.insert(path) }
    }

    private func copySubtree() {
        let text = JSONSerializer.pretty(value, indent: .spaces2)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 子行描述值。
private struct ChildDescriptor: Identifiable {
    let value: JSONValue
    let key: String?
    let path: String
    var id: String { path }
}

/// 便于把对象成员映射为子描述。
private struct JSONMemberWrapper {
    let member: JSONMember
    init(_ member: JSONMember) { self.member = member }
    func descriptor(parentPath: String) -> ChildDescriptor {
        let escapedKey = member.key.contains(".") || member.key.isEmpty
            ? "['\(member.key)']" : ".\(member.key)"
        return ChildDescriptor(value: member.value, key: member.key, path: parentPath + escapedKey)
    }
}
