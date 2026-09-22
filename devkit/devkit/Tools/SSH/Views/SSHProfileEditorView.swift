//
//  SSHProfileEditorView.swift
//  devkit
//
//  M4：连接配置编辑器。密码 / 私钥两种认证。密码与 passphrase 明文随 profile 存 SQLite；
//  私钥文件经 NSOpenPanel 选择后，保存时复制到数据目录 ssh_keys/，profile 记相对文件名。
//

import AppKit
import SwiftUI

struct SSHProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: SSHProfile
    let isNew: Bool
    /// 保存后回调：传出已保存的 profile 与是否立即连接（刷新/连接由调用方处理）。
    let onSaved: (SSHProfile, _ connect: Bool) -> Void

    /// 本次编辑中用户新选择的私钥源文件；保存时复制进数据目录。
    @State private var pendingKeyURL: URL?
    /// 现有/待用私钥的展示名。
    @State private var keyDisplay: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isNew ? "新建 SSH 连接" : "编辑 SSH 连接").font(.headline)
                Spacer()
            }

            Form {
                TextField("名称", text: $draft.name, prompt: Text("例如 生产服务器"))
                TextField("主机", text: $draft.host, prompt: Text("example.com"))
                HStack {
                    TextField("端口", value: $draft.port, format: .number)
                        .frame(width: 90)
                    Spacer()
                }
                TextField("用户名", text: $draft.username)

                Picker("认证方式", selection: $draft.authKind) {
                    ForEach(SSHAuthKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                authSection
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button("保存") { save(connect: false) }
                    .keyboardShortcut(.return, modifiers: [])
                Button("保存并连接") { save(connect: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { keyDisplay = draft.privateKeyFileName != nil ? "已配置私钥" : "未选择" }
    }

    @ViewBuilder
    private var authSection: some View {
        switch draft.authKind {
        case .password:
            SecureField("密码", text: Binding(
                get: { draft.password ?? "" },
                set: { draft.password = $0 }
            ))
        case .key:
            HStack {
                Text("私钥 (PEM)")
                Spacer()
                Text(keyDisplay).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Button("选择…") { pickKey() }
            }
            SecureField("私钥口令（如无留空）", text: Binding(
                get: { draft.keyPassphrase ?? "" },
                set: { draft.keyPassphrase = $0 }
            ))
        }
    }

    // MARK: - Actions

    private func pickKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "选择私钥"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingKeyURL = url
        keyDisplay = url.lastPathComponent
    }

    private func save(connect: Bool) {
        errorMessage = nil
        let trimmedHost = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty else {
            errorMessage = "主机与用户名不能为空"
            return
        }
        draft.host = trimmedHost
        draft.username = trimmedUser
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = trimmedHost
        }

        // 私钥认证：把本次选择的文件复制进数据目录。
        if draft.authKind == .key, let source = pendingKeyURL {
            do {
                let name = try SSHKeyStorage.copyIn(from: source, profileID: draft.id)
                draft.privateKeyFileName = name
            } catch {
                errorMessage = "复制私钥失败：\(error.localizedDescription)"
                return
            }
            pendingKeyURL = nil
        }
        if draft.authKind == .key, draft.privateKeyFileName == nil {
            errorMessage = "请选择私钥文件"
            return
        }

        do {
            try SSHProfileStore.save(draft)
            dismiss()
            onSaved(draft, connect)
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}
