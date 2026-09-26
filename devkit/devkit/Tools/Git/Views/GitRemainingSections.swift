//
//  GitRemainingSections.swift
//  devkit
//
//  「分支 / 历史 / Stash / 远程」四个区块视图。均通过 GitTool 编排动作并自动刷新。
//

import SwiftUI

// MARK: - 分支

struct GitBranchSection: View {
    @Bindable var tool: GitTool
    @State private var showNewBranch = false
    @State private var branchToDelete: GitBranch?
    @State private var newTagName = ""
    @State private var showNewTag = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("分支").font(.subheadline.weight(.semibold))
                Spacer()
                Button("新建分支") { showNewBranch = true }
                Button("新建标签(HEAD)") { showNewTag = true; newTagName = "" }
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本地").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                    ForEach(tool.localBranches) { branchRow($0) }
                    if !tool.remoteBranches.isEmpty {
                        Text("远程").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 10)
                        ForEach(tool.remoteBranches) { branchRow($0) }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .scrollIndicatorBar()
        }
        .sheet(isPresented: $showNewBranch) {
            GitBranchCreateSheet { name, checkout in
                Task { await tool.createBranch(name: name, checkout: checkout) }
            }
        }
        .alert("新建标签", isPresented: $showNewTag) {
            TextField("标签名", text: $newTagName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let name = newTagName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { Task { await tool.createTag(name: name) } }
            }
        }
        .confirmationDialog("删除分支？", isPresented: Binding(
            get: { branchToDelete != nil },
            set: { if !$0 { branchToDelete = nil } }
        ), titleVisibility: .visible, presenting: branchToDelete) { branch in
            Button("强制删除（未合并）", role: .destructive) {
                Task { await tool.deleteBranch(name: branch.name, force: true) }
                branchToDelete = nil
            }
            Button("删除", role: .destructive) {
                Task { await tool.deleteBranch(name: branch.name, force: false) }
                branchToDelete = nil
            }
            Button("取消", role: .cancel) { branchToDelete = nil }
        }
    }

    @ViewBuilder
    private func branchRow(_ branch: GitBranch) -> some View {
        HStack(spacing: 8) {
            // 仅作当前分支的小圆点标识（非可点击控件，避免误导成复选框）。
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.clear)
                .frame(width: 12)
            Text(branch.name).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(branch.isCurrent ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
            if !branch.isRemote && !branch.isCurrent {
                Button("切换") { Task { await tool.checkout(branch: branch.name) } }
                Button("合并") { Task { await tool.merge(branch: branch.name) } }
                    .help("合并到当前分支")
                Button("删除") { branchToDelete = branch }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(branch.isCurrent ? Color.accentColor.opacity(0.10) : .clear))
    }
}

/// 新建分支抽屉：明确区分「创建」与「创建并切换」两个动作（比 alert + Toggle 绑定可靠）。
struct GitBranchCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (_ name: String, _ checkout: Bool) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建分支").font(.headline)
            TextField("分支名", text: $name, prompt: Text("例如 feature/login"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { create(checkout: false) }
            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button("创建") { create(checkout: false) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("创建并切换") { create(checkout: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func create(checkout: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed, checkout)
        dismiss()
    }
}

// MARK: - 历史

struct GitLogSection: View {
    @Bindable var tool: GitTool
    @State private var resetTarget: GitCommit?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("提交历史").font(.subheadline.weight(.semibold))
                Spacer()
                Button("加载更多") { Task { await tool.loadMoreLog() } }
                    .disabled(tool.isBusy || tool.commits.isEmpty)
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(tool.commits) { commit in
                        commitRow(commit)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .scrollIndicatorBar()
        }
        .task { if tool.commits.isEmpty { await tool.loadLog(reset: true) } }
        .confirmationDialog("在此提交处重置当前分支？", isPresented: Binding(
            get: { resetTarget != nil },
            set: { if !$0 { resetTarget = nil } }
        ), titleVisibility: .visible, presenting: resetTarget) { commit in
            Button("Soft（保留改动在暂存）") { run(.soft, commit) }
            Button("Mixed（保留改动不暂存）") { run(.mixed, commit) }
            Button("Hard（丢弃改动）", role: .destructive) { run(.hard, commit) }
            Button("取消", role: .cancel) { resetTarget = nil }
        }
    }

    private func run(_ mode: GitRepository.ResetMode, _ commit: GitCommit) {
        resetTarget = nil
        Task { await tool.reset(mode: mode, to: commit.shortHash) }
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(commit.shortHash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(commit.subject).font(.system(size: 12)).lineLimit(1)
                Text("\(commit.author) · \(commit.relativeDate)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            if !commit.refs.isEmpty {
                Text(commit.refs).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.03)))
        .contextMenu {
            Button("Cherry-pick 到当前分支") { Task { await tool.cherryPick(hash: commit.hash) } }
            Button("在此处重置…") { resetTarget = commit }
            Divider()
            Button("复制完整哈希") {
                let pb = NSPasteboard.general; pb.clearContents(); pb.setString(commit.hash, forType: .string)
            }
        }
    }
}

// MARK: - Stash

struct GitStashSection: View {
    @Bindable var tool: GitTool
    @State private var message = ""
    @State private var showPush = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Stash").font(.subheadline.weight(.semibold))
                Spacer()
                Button("暂存当前改动") { showPush = true; message = "" }
                    .disabled(tool.isBusy)
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if tool.stashes.isEmpty {
                        Text("没有 stash 记录").font(.callout).foregroundStyle(.secondary)
                            .padding(.top, 24).frame(maxWidth: .infinity)
                    } else {
                        ForEach(tool.stashes) { stash in
                            HStack(spacing: 8) {
                                Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
                                Text("stash@{\(stash.index)}").font(.system(size: 11, design: .monospaced))
                                Text(stash.message).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Button("Pop") { Task { await tool.stashPop(index: stash.index) } }
                                Button("Apply") { Task { await tool.stashApply(index: stash.index) } }
                                Button("Drop", role: .destructive) { Task { await tool.stashDrop(index: stash.index) } }
                            }
                            .buttonStyle(.borderless).controlSize(.small)
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.03)))
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .scrollIndicatorBar()
        }
        .task { await tool.refreshStashes() }
        .alert("新建 Stash", isPresented: $showPush) {
            TextField("描述（可留空）", text: $message)
            Button("取消", role: .cancel) {}
            Button("暂存") { Task { await tool.stashPush(message: message) } }
        }
    }
}

// (GitRemoteSection 已移除：fetch/pull/push 在横幅与提交栏；仓库/密钥/删除管理移至设置页。)
