//
//  GitChangesSection.swift
//  devkit
//
//  「变更」区块：分三棵树——未暂存（工作区改动/未跟踪）、未提交（已暂存待提交）、未推送（有提交未推
//  到远程）；冲突存在时置顶。底部提交栏（消息 + Amend + 提交 + 推送）。推送仅在「有未推送提交」时可点。
//

import SwiftUI

struct GitChangesSection: View {
    @Bindable var tool: GitTool
    @State private var message = ""
    @State private var amend = false

    private var hasStaged: Bool { !tool.status.staged.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("工作区变更").font(.subheadline.weight(.semibold))
                Spacer()
                Button("全部暂存") { Task { await tool.stageAll() } }
                    .disabled(tool.isBusy)
                Button("全部取消") { Task { await tool.unstageAll() } }
                    .disabled(tool.isBusy)
            }
            .padding(.horizontal, 4).padding(.vertical, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !tool.status.conflicted.isEmpty {
                        fileGroup("冲突", color: .red) {
                            ForEach(tool.status.conflicted) { fileRow($0, kind: .conflict) }
                        }
                    }
                    unstagedGroup
                    stagedGroup
                    unpushedGroup

                    if isEmpty {
                        Label("工作区干净，且无待推送提交", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .scrollIndicatorBar()

            Divider()
            commitBar
        }
    }

    private var isEmpty: Bool {
        tool.status.entries.isEmpty && tool.unpushedCommits.isEmpty
    }

    // MARK: - 三棵树

    /// 未暂存：工作区已改但未 stage 的跟踪文件 + 未跟踪文件。
    private var unstagedGroup: some View {
        let tracked = tool.status.unstaged
        let untracked = tool.status.untracked
        return Group {
            if !tracked.isEmpty || !untracked.isEmpty {
                fileGroup("未暂存", color: .orange) {
                    ForEach(tracked) { fileRow($0, kind: .unstaged) }
                    ForEach(untracked) { fileRow($0, kind: .untracked) }
                }
            }
        }
    }

    /// 未提交：已暂存、等待提交的改动。
    private var stagedGroup: some View {
        Group {
            if hasStaged {
                fileGroup("未提交（已暂存）", color: .green) {
                    ForEach(tool.status.staged) { fileRow($0, kind: .staged) }
                }
            }
        }
    }

    /// 未推送：本分支领先上游、尚未推到远程的提交。无内容时与未暂存/未提交一致隐藏整棵树（推送按钮在底部提交栏）。
    @ViewBuilder
    private var unpushedGroup: some View {
        if tool.hasUnpushed {
            fileGroup("未推送", color: .accentColor, count: tool.unpushedCommits.count) {
                ForEach(tool.unpushedCommits) { commitRow($0) }
            }
        }
    }

    // MARK: - 行

    private enum RowKind { case staged, unstaged, untracked, conflict }

    private func fileGroup<Trailing: View, Content: View>(
        _ title: String, color: Color, count: Int? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
                if let count, count > 0 { Text("\(count)").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                trailing()
            }
            content()
        }
    }

    private func fileRow(_ entry: GitFileEntry, kind: RowKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kind == .untracked ? "questionmark.folder" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(entry.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Text(entry.badge).font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            switch kind {
            case .staged:
                Button("取消暂存") { Task { await tool.unstage(paths: [entry.path]) } }
            case .unstaged:
                Button("暂存") { Task { await tool.stage(paths: [entry.path]) } }
                Button("丢弃") { Task { await tool.discard(paths: [entry.path]) } }
                    .foregroundStyle(.red)
            case .untracked:
                Button("暂存") { Task { await tool.stage(paths: [entry.path]) } }
            case .conflict:
                Button("我方") { Task { await tool.resolveConflict(file: entry.path, side: .ours) } }
                Button("对方") { Task { await tool.resolveConflict(file: entry.path, side: .theirs) } }
                Button("标记已解决") { Task { await tool.markResolved(file: entry.path) } }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.03)))
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        HStack(spacing: 8) {
            Text(commit.shortHash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(commit.subject).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Text("\(commit.author) · \(commit.relativeDate)")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.03)))
    }

    // MARK: - 提交栏

    private var commitBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("提交信息（⌘↵ 提交）", text: $message, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .onSubmit { commit() }
            HStack {
                Toggle("Amend", isOn: $amend)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Button("提交") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(tool.isBusy || (!amend && !hasStaged)
                              || (!amend && message.trimmingCharacters(in: .whitespaces).isEmpty))
                Button("推送") { Task { await tool.push() } }
                    .disabled(tool.isBusy || !tool.hasUnpushed)
                    .help(tool.hasUnpushed ? "git push" : "没有待推送的提交")
            }
        }
        .padding(10)
    }

    private func commit() {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard amend || (!msg.isEmpty && hasStaged) else { return }
        Task {
            await tool.commit(message: msg.isEmpty ? " " : msg, amend: amend)
            message = ""
            amend = false
        }
    }
}
