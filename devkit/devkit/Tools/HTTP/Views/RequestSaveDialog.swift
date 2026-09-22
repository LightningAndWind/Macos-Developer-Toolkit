//
//  RequestSaveDialog.swift
//  devkit
//
//  M5：HTTP 首次 ⌘S 弹出的"保存位置"对话框 —— 命名 + 选择多级文件夹 + 就地新建文件夹。
//

import SwiftUI

struct RequestSaveDialog: View {
    @Environment(AppState.self) private var appState
    let tabID: UUID
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var destination: UUID?
    @State private var newFolderName: String = ""
    @State private var folders: [HTTPFolder] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("保存请求")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("名称").font(.caption).foregroundStyle(.secondary)
                TextField("请求名称", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("保存到文件夹").font(.caption).foregroundStyle(.secondary)
                FolderPickerTree(selection: $destination, folders: folders)
                    .frame(height: 160)
            }

            HStack(spacing: 8) {
                TextField("新建文件夹名称", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createFolder)
                Button("新建文件夹", action: createFolder)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Spacer()
                Button("取消") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            folders = HTTPCollectionStore.allFolders()
            if name.isEmpty {
                name = appState.httpTool(forTab: tabID)?.dynamicTabTitle ?? "未命名请求"
            }
        }
    }

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let created = HTTPCollectionStore.createFolder(name: trimmed, parentID: destination) {
            destination = created.id   // 新建后自动选中新文件夹
        }
        newFolderName = ""
        folders = HTTPCollectionStore.allFolders()
    }

    private func save() {
        if appState.commitHTTPSave(tabID: tabID, name: name, folderID: destination) {
            onDismiss()
        }
    }
}
