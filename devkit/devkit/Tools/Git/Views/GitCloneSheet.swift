//
//  GitCloneSheet.swift
//  devkit
//
//  克隆仓库：填 URL + 选目标父目录 + 别名 + 绑定密钥。用选定密钥注入 GIT_SSH_COMMAND 执行
//  `git clone`，实时输出到控制台；成功后自动登记为仓库（folderID 落在选择器当前目标文件夹）。
//

import AppKit
import SwiftUI

struct GitCloneSheet: View {
    @Environment(\.dismiss) private var dismiss
    let targetFolder: UUID?
    let keys: [GitKey]
    let onCloned: (GitRepo) -> Void

    @State private var url = ""
    @State private var destination = ""
    @State private var alias = ""
    @State private var keyID: UUID?
    @State private var lines: [String] = []
    @State private var running = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("克隆仓库").font(.headline)

            Form {
                TextField("仓库 URL", text: $url, prompt: Text("git@github.com:owner/repo.git"))
                HStack {
                    TextField("目标目录", text: $destination).disabled(true).lineLimit(1)
                    Button("选择…") { pickDestination() }
                }
                TextField("别名（留空取仓库名）", text: $alias)
                Picker("绑定密钥", selection: Binding(
                    get: { keyID }, set: { keyID = $0 }
                )) {
                    Text("默认").tag(UUID?.none)
                    ForEach(keys) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            .formStyle(.grouped)
            .disabled(running)

            if !lines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .scrollIndicators(.never)
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button(running ? "取消中…" : "关闭", role: .cancel) { dismiss() }
                    .disabled(running)
                Spacer()
                Button {
                    startClone()
                } label: {
                    if running {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("克隆中…") }
                    } else {
                        Text("克隆")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || url.trimmingCharacters(in: .whitespaces).isEmpty || destination.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if destination.isEmpty { destination = NSHomeDirectory() }
        }
    }

    private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择父目录"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        destination = u.path
    }

    private func startClone() {
        errorMessage = nil
        running = true
        lines = []
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let env = GitSSHBridge.environment(keyID: keyID)
        let parent = destination
        // 子目录名：别名清洗 or 从 URL 推导。
        var sub = alias.trimmingCharacters(in: .whitespaces)
        if sub.isEmpty { sub = GitRepository.repoName(from: trimmedURL) }
        let chosenAlias = sub

        Task {
            do {
                let path = try await GitRepository.clone(url: trimmedURL,
                                                         into: parent,
                                                         subdirectory: sub,
                                                         environment: env,
                                                         onLine: { lines.append($0) })
                let repo = GitRepo(folderID: targetFolder, alias: chosenAlias, path: path, keyID: keyID)
                try GitRepoStore.save(repo)
                dismiss()
                onCloned(repo)
            } catch {
                errorMessage = error.localizedDescription
                running = false
            }
        }
    }
}
