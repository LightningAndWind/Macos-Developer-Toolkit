//
//  GitRepoDetailView.swift
//  devkit
//
//  当前仓库详情：头部（仓库名 + 换个仓库 + 登记/克隆/密钥管理菜单）+ 状态横幅 + 分区（变更/分支/历史/
//  Stash/远程）。分区切换用按钮式分段控件（避免 Picker 文本在 macOS 15 下的 I 型光标）。
//  出现时刷新只读数据；变基进行中给出醒目标识。
//

import SwiftUI

struct GitRepoDetailView: View {
    @Bindable var tool: GitTool
    @Environment(AppState.self) private var appState

    @State private var keys: [GitKey] = []
    @State private var editing: GitRepo?
    @State private var cloning = false
    @State private var showKeys = false
    @State private var showRemoteEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            banner
            sectionSwitcher
            Divider()
            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            keys = GitKeyStore.all()
            await tool.refreshAll()
        }
        .sheet(item: $editing) { repo in
            GitRepoEditorView(draft: repo, isNew: false, keys: keys) { _ in
                keys = GitKeyStore.all()
            }
        }
        .sheet(isPresented: $cloning) {
            GitCloneSheet(targetFolder: nil, keys: keys) { _ in
                keys = GitKeyStore.all()
            }
        }
        .sheet(isPresented: $showKeys) {
            GitKeyManagerView { keys = GitKeyStore.all() }
        }
        .sheet(isPresented: $showRemoteEditor) {
            GitRemoteEditorSheet(tool: tool)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                if let id = appState.tabID(for: tool) { appState.gitChooserTabID = id }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left.arrow.right.circle")
                    Text(tool.selectedRepo?.alias ?? "仓库")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .help("换个仓库 / 打开已保存")

            Spacer()

            Menu {
                Button("登记仓库…", systemImage: "folder.badge.plus") {
                    editing = GitRepo(folderID: nil, alias: "", path: "", keyID: nil)
                }
                Button("克隆仓库…", systemImage: "arrow.down.circle") { cloning = true }
                Divider()
                Button("密钥管理…", systemImage: "key.horizontal") { showKeys = true }
                Divider()
                Button("刷新", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await tool.refreshAll() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .pointingHandOnHover()
    }

    // MARK: - 状态横幅

    private var banner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    branchIndicator
                    if tool.status.ahead > 0 { chip("↑\(tool.status.ahead)", .green) }
                    if tool.status.behind > 0 { chip("↓\(tool.status.behind)", .orange) }
                    if tool.status.isRebasing { chip("变基中", .purple) }
                    // 冲突不再弹错误：在横幅常驻提示，点击回变更区逐块解决。
                    if tool.hasConflict {
                        Button {
                            tool.section = .changes
                        } label: {
                            chip("⚠ 冲突 \(tool.status.conflicted.count) 个待解决", .red)
                        }
                        .buttonStyle(.plain)
                        .help("点击查看冲突文件")
                    }
                }
                if let repo = tool.selectedRepo {
                    Text(repo.path)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                remoteRow
            }
            Spacer()
            keyIndicator
            bannerButton(isWorking: tool.isRefreshing,
                         symbol: "arrow.triangle.2.circlepath",
                         help: "刷新工作区",
                         disabled: tool.isBusy) {
                Task { await tool.refreshWorkspace() }
            }
            bannerButton(isWorking: tool.isPulling,
                         symbol: "arrow.down.circle",
                         help: "拉取代码 (git pull)",
                         disabled: tool.isBusy) {
                Task { await tool.pullCode() }
            }
        }
        .buttonStyle(.borderless)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }

    /// 顶部当前分支：点击弹出本地分支列表，点选其他分支即切换（与「绑定密钥」同构：
    /// borderless Menu + 勾选当前项 + 手指光标）。分支尚未加载或操作进行中时退回纯展示/禁用。
    @ViewBuilder
    private var branchIndicator: some View {
        if tool.localBranches.isEmpty {
            branchLabel
        } else {
            Menu {
                ForEach(tool.localBranches) { branch in
                    Button {
                        if !branch.isCurrent { Task { await tool.checkout(branch: branch.name) } }
                    } label: {
                        labelRow(branch.name, checked: branch.isCurrent)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    branchLabel
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(tool.isBusy)
            .help("切换分支（点击选择本地分支）")
            .pointingHandOnHover()
        }
    }

    private var branchLabel: some View {
        Label(tool.status.branch, systemImage: "arrow.triangle.branch")
            .font(.system(size: 12, design: .monospaced))
    }

    /// 横幅图标按钮：进行中时就地显示转圈（固定尺寸，不抖布局）。
    private func bannerButton(isWorking: Bool, symbol: String, help: String,
                              disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                }
            }
            .frame(width: 18, height: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(disabled)
    }

    /// 当前仓库绑定密钥：点击弹出菜单直接改绑（与「新增仓库」不同，仅换密钥）。
    @ViewBuilder
    private var keyIndicator: some View {
        if let repo = tool.selectedRepo {
            Menu {
                Button { tool.rebindKey(to: nil) } label: {
                    labelRow("不绑定（系统默认）", checked: repo.keyID == nil)
                }
                if !keys.isEmpty { Divider() }
                ForEach(keys) { key in
                    Button { tool.rebindKey(to: key.id) } label: {
                        labelRow("\(key.name) · \(key.algorithm.label)", checked: repo.keyID == key.id)
                    }
                }
            } label: {
                if let keyID = repo.keyID, let key = GitKeyStore.load(id: keyID) {
                    Label(key.name, systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                } else {
                    Label("默认密钥", systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("绑定密钥（点击改绑）")
        }
    }

    /// 远程地址行：展示首选远程（origin 优先），铅笔按钮弹出配置抽屉；未配置时给出引导文案。
    private var remoteRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            if let remote = tool.primaryRemote {
                Text(remote.displayURL)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("未配置远程地址")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Button {
                showRemoteEditor = true
            } label: {
                Image(systemName: "pencil").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .pointingHandOnHover()
            .help("配置远程仓库地址")
            .disabled(tool.isBusy)
        }
    }

    private func labelRow(_ text: String, checked: Bool) -> some View {
        HStack { Text(text); Spacer(); if checked { Image(systemName: "checkmark") } }
    }

    // MARK: - 分区切换（按钮式，避免 I 型光标）

    private var sectionSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(GitTool.Section.allCases) { section in
                SectionChip(section: section, isSelected: tool.section == section) {
                    tool.section = section
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch tool.section {
        case .changes: GitChangesSection(tool: tool)
        case .branches: GitBranchSection(tool: tool)
        case .log: GitLogSection(tool: tool)
        case .stash: GitStashSection(tool: tool)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

/// 单个分区切换胶囊按钮：按钮天然用箭头/手指光标，不会像可选中文本那样变 I 型。
private struct SectionChip: View {
    let section: GitTool.Section
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: section.symbol).font(.system(size: 10))
                Text(section.rawValue).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }
}

/// 远程地址配置抽屉：逐条展示远程并可直接改地址（保存时 fetch/push 一并更新）；无远程时可新增。
struct GitRemoteEditorSheet: View {
    @Bindable var tool: GitTool
    @Environment(\.dismiss) private var dismiss

    /// 每个远程一份编辑草稿（key = 远程名）：保存前输入框与 tool.remotes 互不干扰。
    @State private var drafts: [String: String] = [:]
    @State private var newName = ""
    @State private var newURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("远程仓库地址").font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if tool.remotes.isEmpty {
                        Text("尚未配置远程仓库，可在下方添加。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(tool.remotes) { remote in
                        remoteEditorRow(remote)
                    }
                }
                .padding(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Divider()
            addRemoteRow
            HStack {
                Spacer()
                Button("完成") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
        .task {
            drafts = Dictionary(uniqueKeysWithValues: tool.remotes.map { ($0.name, $0.displayURL) })
        }
    }

    @ViewBuilder
    private func remoteEditorRow(_ remote: GitRemote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(remote.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Button("保存") {
                    let url = trimmed(drafts[remote.name] ?? "")
                    guard !url.isEmpty else { return }
                    Task {
                        await tool.setRemoteURL(name: remote.name, url: url)
                        drafts[remote.name] = url
                    }
                }
                .disabled(!canSave(remote))
            }
            TextField("远程地址", text: Binding(
                get: { drafts[remote.name] ?? "" },
                set: { drafts[remote.name] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
        }
    }

    private var addRemoteRow: some View {
        HStack(spacing: 8) {
            Text("新增").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("名称", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 110)
            TextField("https://… 或 git@…", text: $newURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            Button("添加") {
                let n = trimmed(newName), u = trimmed(newURL)
                guard !n.isEmpty, !u.isEmpty else { return }
                Task {
                    await tool.addRemote(name: n, url: u)
                    drafts[n] = u
                    newName = ""
                    newURL = ""
                }
            }
            .disabled(trimmed(newName).isEmpty || trimmed(newURL).isEmpty)
        }
    }

    private func canSave(_ remote: GitRemote) -> Bool {
        let url = trimmed(drafts[remote.name] ?? "")
        return !url.isEmpty && url != remote.displayURL
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
