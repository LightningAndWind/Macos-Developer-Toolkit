//
//  SSHStartupChooser.swift
//  devkit
//
//  M4：打开新 SSH 标签（或"换个目标"）时的选择弹窗，交互对齐 HTTPStartupChooser：
//  ① 本地终端：直接进入本机 shell；
//  ② 新建 SSH 连接：弹出编辑器（嵌套 sheet），保存后可直接连接；
//  ③ 打开已保存：浏览多级文件夹 + 已有连接，点连接即连接；底部可新建文件夹。
//

import SwiftUI

struct SSHStartupChooser: View {
    @Environment(AppState.self) private var appState
    let tabID: UUID
    let onDismiss: () -> Void

    @State private var nodes: [SSHCollectionNode] = []
    @State private var targetFolder: UUID?
    @State private var newFolderName = ""

    // 编辑器（嵌套 sheet）
    @State private var editing: SSHProfile?
    @State private var editingIsNew = false

    // 文件夹重命名 / 删除
    @State private var renamingFolder: SSHFolder?
    @State private var renameText = ""
    @State private var folderToDelete: SSHFolder?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("SSH 连接")
                    .font(.headline)
                Spacer()
                Button(action: closeAndMaybeDropTab) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            // 块①：本地 + 新建
            HStack(spacing: 10) {
                primaryCard(icon: "house", title: "本地终端", subtitle: "本机 shell") {
                    appState.sshTool(forTab: tabID)?.startLocal()
                    onDismiss()
                }
                primaryCard(icon: "plus.square.on.square", title: "新建 SSH 连接", subtitle: "配置一台新主机") {
                    beginNew()
                }
            }

            // 块②：打开已保存
            VStack(alignment: .leading, spacing: 8) {
                Text("打开已保存").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("点击连接 = 连接该主机；点击文件夹 = 选为新建文件夹的位置；右键可编辑/删除")
                    .font(.caption).foregroundStyle(.secondary)
                browser
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
        .sheet(item: $editing) { profile in
            SSHProfileEditorView(draft: profile, isNew: editingIsNew) { saved, connect in
                refresh()
                if connect { open(saved) }
            }
        }
        .alert("重命名文件夹", isPresented: Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renamingFolder = nil }
            Button("确定") { commitRenameFolder() }
        }
        .confirmationDialog("删除文件夹及其中的所有连接？",
                            isPresented: Binding(get: { folderToDelete != nil },
                                                 set: { if !$0 { folderToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let f = folderToDelete { SSHProfileStore.deleteFolder(id: f.id); refresh() }
                folderToDelete = nil
            }
            Button("取消", role: .cancel) { folderToDelete = nil }
        }
    }

    private var browser: some View {
        ScrollView {
            SSHTreeView(nodes: nodes,
                        onOpen: { open($0) },
                        onEdit: { beginEdit($0) },
                        onDelete: { delete($0) },
                        onEditFolder: { beginRenameFolder($0) },
                        onDeleteFolder: { folderToDelete = $0 },
                        targetFolder: $targetFolder)
                .padding(6)
        }
        // 原生滚动条在系统「始终显示滚动条」下会带不透明白色轨道，改用自绘指示条（同侧栏标签栏）。
        .scrollIndicators(.never)
        .scrollIndicatorBar()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
    }

    private var parentPlaceholder: String {
        guard let targetFolder,
              let name = SSHProfileStore.allFolders().first(where: { $0.id == targetFolder })?.name
        else { return "在根目录新建文件夹…" }
        return "在「\(name)」下新建…"
    }

    // MARK: - Actions

    private func refresh() {
        nodes = SSHProfileStore.buildTree()
    }

    private func beginNew() {
        editingIsNew = true
        editing = SSHProfile(folderID: targetFolder, name: "", host: "", port: SSHProfile.defaultPort,
                             username: "", authKind: .password)
    }

    private func beginEdit(_ profile: SSHProfile) {
        editingIsNew = false
        editing = profile
    }

    private func delete(_ profile: SSHProfile) {
        SSHProfileStore.delete(profile.id)
        refresh()
    }

    private func open(_ profile: SSHProfile) {
        guard let tool = appState.sshTool(forTab: tabID) else { onDismiss(); return }
        tool.connect(to: profile)
        appState.tabManager.rename(tabID: tabID, to: profile.name)
        onDismiss()
    }

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = SSHProfileStore.createFolder(name: trimmed, parentID: targetFolder)
        newFolderName = ""
        refresh()
    }

    private func beginRenameFolder(_ folder: SSHFolder) {
        renameText = folder.name
        renamingFolder = folder
    }

    private func commitRenameFolder() {
        if let f = renamingFolder { SSHProfileStore.renameFolder(id: f.id, name: renameText) }
        renamingFolder = nil
        refresh()
    }

    /// 右上角叉：若该标签尚未选定会话（空标签）则一并丢弃；否则仅关闭弹窗保留当前会话。
    private func closeAndMaybeDropTab() {
        if appState.sshTool(forTab: tabID)?.sessionKind == nil {
            appState.closeTab(tabID)
        }
        onDismiss()
    }
}

/// 弹窗顶部的大号动作卡片。
private func primaryCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.tint)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Palette.accentStroke))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
}
