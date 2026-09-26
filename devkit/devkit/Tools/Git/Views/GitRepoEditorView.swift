//
//  GitRepoEditorView.swift
//  devkit
//
//  登记 / 编辑一个 Git 仓库：填别名 + 选工作目录（NSOpenPanel）+ 选绑定密钥。
//  保存前校验目录是有效 git 仓库（异步 isGitRepo）。对照 SSHProfileEditorView。
//

import AppKit
import SwiftUI

struct GitRepoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: GitRepo
    let isNew: Bool
    let keys: [GitKey]
    /// 保存后回调（刷新 / 打开由调用方处理）。
    let onSaved: (GitRepo) -> Void

    @State private var validating = false
    @State private var validationOK: Bool?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "登记 Git 仓库" : "编辑仓库").font(.headline)

            Form {
                TextField("别名", text: $draft.alias, prompt: Text("例如 后端服务"))
                HStack {
                    TextField("路径", text: $draft.path, prompt: Text("仓库工作目录"))
                        .disabled(true)
                        .lineLimit(1)
                    Button("选择…") { pickPath() }
                }
                if let validationOK {
                    Label(validationOK ? "有效的 Git 仓库" : "该目录不是 Git 仓库",
                          systemImage: validationOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(validationOK ? Color.green : Color.orange)
                }

                Picker("绑定密钥", selection: Binding(
                    get: { draft.keyID },
                    set: { draft.keyID = $0 }
                )) {
                    Text("默认（系统 ssh-agent / 仓库配置）").tag(UUID?.none)
                    ForEach(keys) { key in
                        Text("\(key.name) · \(key.algorithm.label)").tag(UUID?.some(key.id))
                    }
                }

                if draft.keyID != nil {
                    Text("远程操作时以该密钥认证（运行时注入 GIT_SSH_COMMAND，跨设备按当前目录路径生效）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                if validating { ProgressView().controlSize(.small) }
                Button("保存") { save() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func pickPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择仓库目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.path = url.path
        if draft.alias.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.alias = url.lastPathComponent
        }
        validate(url.path)
    }

    private func validate(_ path: String) {
        guard !path.isEmpty else { validationOK = nil; return }
        validating = true
        validationOK = nil
        Task {
            let ok = await GitRepository.isGitRepo(path)
            validationOK = ok
            validating = false
        }
    }

    private func save() {
        errorMessage = nil
        let alias = draft.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.path.isEmpty else { errorMessage = "请选择仓库路径"; return }
        guard FileManager.default.fileExists(atPath: draft.path) else {
            errorMessage = "路径不存在"; return
        }
        draft.alias = alias.isEmpty ? URL(fileURLWithPath: draft.path).lastPathComponent : alias
        do {
            try GitRepoStore.save(draft)
            dismiss()
            onSaved(draft)
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}
