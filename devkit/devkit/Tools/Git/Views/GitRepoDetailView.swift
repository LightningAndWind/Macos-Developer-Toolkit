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
                    Label(tool.status.branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 12, design: .monospaced))
                    if tool.status.ahead > 0 { chip("↑\(tool.status.ahead)", .green) }
                    if tool.status.behind > 0 { chip("↓\(tool.status.behind)", .orange) }
                    if tool.status.isRebasing { chip("变基中", .purple) }
                }
                if let repo = tool.selectedRepo {
                    Text(repo.path)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
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
