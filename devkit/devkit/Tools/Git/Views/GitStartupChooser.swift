//
//  GitStartupChooser.swift
//  devkit
//
//  打开新 Git 标签（或"换个仓库"）时的选择弹窗，交互对齐 SSHStartupChooser：
//  ① 登记仓库：路径 + 别名 + 绑定密钥（弹编辑器）；② 克隆仓库；③ 打开已保存（多级文件夹树）；
//  底部新建文件夹；顶部另置「密钥管理」入口。
//

import SwiftUI

struct GitStartupChooser: View {
    @Environment(AppState.self) private var appState
    let tabID: UUID
    let onDismiss: () -> Void

    @State private var nodes: [GitCollectionNode] = []
    @State private var keys: [GitKey] = []
    @State private var targetFolder: UUID?
    @State private var newFolderName = ""

    @State private var editing: GitRepo?
    @State private var editingIsNew = false
    @State private var cloning = false
    @State private var showKeys = false

    @State private var renamingFolder: GitFolder?
    @State private var renameText = ""
    @State private var folderToDelete: GitFolder?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Git 仓库").font(.headline)
                Spacer()
                Button {
                    showKeys = true
                } label: {
                    Label("密钥管理", systemImage: "key.horizontal")
                }
                .controlSize(.small)
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

            HStack(spacing: 10) {
                primaryCard(icon: "folder.badge.plus", title: "登记仓库", subtitle: "已有本地仓库") {
                    beginNew()
                }
                primaryCard(icon: "arrow.down.circle", title: "克隆仓库", subtitle: "从远程拉取") {
                    cloning = true
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("打开已保存").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("点击仓库 = 打开；点击文件夹 = 选为新建位置；右键可编辑 / 删除")
                    .font(.caption).foregroundStyle(.secondary)
                browser.frame(height: 220)
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
        .frame(width: 440)
        .onAppear { refresh() }
        .sheet(item: $editing) { repo in
            GitRepoEditorView(draft: repo, isNew: editingIsNew, keys: keys) { saved in
                refresh()
                open(saved)
            }
        }
        .sheet(isPresented: $cloning) {
            GitCloneSheet(targetFolder: targetFolder, keys: keys) { repo in
                refresh()
                open(repo)
            }
        }
        .sheet(isPresented: $showKeys) { GitKeyManagerView() }
        .alert("重命名文件夹", isPresented: Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renamingFolder = nil }
            Button("确定") { commitRenameFolder() }
        }
        .confirmationDialog("删除文件夹及其中的所有仓库登记？",
                            isPresented: Binding(get: { folderToDelete != nil },
                                                 set: { if !$0 { folderToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let f = folderToDelete { GitRepoStore.deleteFolder(id: f.id); refresh() }
                folderToDelete = nil
            }
            Button("取消", role: .cancel) { folderToDelete = nil }
        }
    }

    private var browser: some View {
        ScrollView {
            GitRepoTreeView(nodes: nodes,
                            onSelect: { open($0) },
                            onEdit: { beginEdit($0) },
                            onDelete: { delete($0) },
                            onRenameFolder: { beginRenameFolder($0) },
                            onDeleteFolder: { folderToDelete = $0 },
                            targetFolder: $targetFolder)
                .padding(6)
        }
        .scrollIndicators(.never)
        .scrollIndicatorBar()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
    }

    private var parentPlaceholder: String {
        guard let targetFolder,
              let name = GitRepoStore.allFolders().first(where: { $0.id == targetFolder })?.name
        else { return "在根目录新建文件夹…" }
        return "在「\(name)」下新建…"
    }

    // MARK: - Actions

    private func refresh() {
        nodes = GitRepoStore.buildTree()
        keys = GitKeyStore.all()
    }

    private func beginNew() {
        editingIsNew = true
        editing = GitRepo(folderID: targetFolder, alias: "", path: "", keyID: nil)
    }

    private func beginEdit(_ repo: GitRepo) {
        editingIsNew = false
        editing = repo
    }

    private func delete(_ repo: GitRepo) {
        GitRepoStore.delete(repo.id)
        refresh()
    }

    private func open(_ repo: GitRepo) {
        guard let tool = appState.gitTool(forTab: tabID) else { onDismiss(); return }
        tool.select(repo: repo)
        appState.tabManager.rename(tabID: tabID, to: repo.alias)
        onDismiss()
    }

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = GitRepoStore.createFolder(name: trimmed, parentID: targetFolder)
        newFolderName = ""
        refresh()
    }

    private func beginRenameFolder(_ folder: GitFolder) {
        renameText = folder.name
        renamingFolder = folder
    }

    private func commitRenameFolder() {
        if let f = renamingFolder { GitRepoStore.renameFolder(id: f.id, name: renameText) }
        renamingFolder = nil
        refresh()
    }

    private func closeAndMaybeDropTab() {
        if appState.gitTool(forTab: tabID)?.selectedRepo == nil {
            appState.closeTab(tabID)
        }
        onDismiss()
    }
}

/// 弹窗顶部的大号动作卡片（与 SSHStartupChooser 同款）。
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
