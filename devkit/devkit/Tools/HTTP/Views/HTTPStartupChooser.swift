//
//  HTTPStartupChooser.swift
//  devkit
//
//  M5：打开新 HTTP 标签时的选择入口。两块：
//  ① 新建请求：进入可先发请求、可 ⌘S 保存的空白标签；
//  ② 打开已保存：浏览多级文件夹 + 已保存请求，选中即载入该标签并绑定为已保存。
//

import SwiftUI

struct HTTPStartupChooser: View {
    @Environment(AppState.self) private var appState
    let tabID: UUID
    let onDismiss: () -> Void

    @State private var nodes: [HTTPCollectionNode] = []
    @State private var newFolderName: String = ""
    /// 选定的“新建文件夹”目标父级；nil = 根目录。
    @State private var targetFolder: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("新建 HTTP 请求")
                    .font(.headline)
                Spacer()
                Button(action: closeAndDropTab) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭（丢弃此空标签）")
            }

            // 块①：新建
            Button(action: createBlank) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 22))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("新建请求").font(.system(size: 14, weight: .semibold))
                        Text("空白请求，可先发送再 ⌘S 保存")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Palette.accentStroke))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            // 块②：打开已保存
            VStack(alignment: .leading, spacing: 8) {
                Text("打开已保存").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("点击某个文件夹 = 选为其新建子文件夹的位置；点击请求 = 直接打开")
                    .font(.caption).foregroundStyle(.secondary)
                CollectionBrowser(nodes: nodes, onOpen: open, targetFolder: $targetFolder)
                    .frame(height: 220)
                HStack(spacing: 8) {
                    TextField(parentPlaceholder, text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(createFolder)
                    Button("新建文件夹", action: createFolder)
                        .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { refresh() }
    }

    private func refresh() {
        nodes = HTTPCollectionStore.buildTree()
    }

    private func createBlank() {
        // 保留已建的空白标签，仅关闭选择框。
        onDismiss()
    }

    /// 右上角叉：关闭选择框的同时直接丢弃这个尚未使用的空标签。
    private func closeAndDropTab() {
        appState.closeTab(tabID)
        onDismiss()
    }

    /// 新建文件夹输入框占位文案：提示将建在哪个父级下。
    private var parentPlaceholder: String {
        guard let targetFolder else { return "在根目录新建文件夹…" }
        let name = HTTPCollectionStore.allFolders().first { $0.id == targetFolder }?.name ?? "文件夹"
        return "在「\(name)」下新建文件夹…"
    }

    private func open(_ record: HTTPSavedRequest) {
        if let tool = appState.httpTool(forTab: tabID) {
            tool.applySaved(record)
            appState.tabManager.rename(tabID: tabID, to: record.name)
            appState.saveSession()
        }
        onDismiss()
    }

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = HTTPCollectionStore.createFolder(name: trimmed, parentID: targetFolder)
        newFolderName = ""
        refresh()
    }
}
