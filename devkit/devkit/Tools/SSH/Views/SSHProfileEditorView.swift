//
//  SSHProfileEditorView.swift
//  devkit
//
//  M4：会话记录编辑器。记录分两类：
//   - 本地终端：只配名称 + 「默认进入的文件夹」（本机目录，用面板选择）；
//   - 远程 SSH：主机 / 端口 / 用户名 / 认证方式（密码或私钥），可选「默认目录」（远端路径，登录后自动 cd）。
//  密码与 passphrase 明文随 profile 存 SQLite；私钥文件经 NSOpenPanel 选择后，
//  保存时复制到数据目录 ssh_keys/，profile 记相对文件名。
//

import AppKit
import SwiftUI

struct SSHProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: SSHProfile
    let isNew: Bool
    /// 限定会话类型：非 nil 时隐藏类型选择并强制该类型（SFTP 选择器只支持远程连接）。
    var forcedKind: SSHSessionKind?
    /// 保存后回调：传出已保存的 profile 与是否立即打开 / 连接（刷新由调用方处理）。
    let onSaved: (SSHProfile, _ connect: Bool) -> Void

    /// 本次编辑中用户新选择的私钥源文件；保存时复制进数据目录。
    @State private var pendingKeyURL: URL?
    /// 现有/待用私钥的展示名。
    @State private var keyDisplay: String = ""
    @State private var errorMessage: String?

    init(draft: SSHProfile,
         isNew: Bool,
         forcedKind: SSHSessionKind? = nil,
         onSaved: @escaping (SSHProfile, _ connect: Bool) -> Void) {
        self._draft = State(initialValue: draft)
        self.isNew = isNew
        self.forcedKind = forcedKind
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.headline)
                Spacer()
            }

            Form {
                if forcedKind == nil {
                    Picker("类型", selection: $draft.kind) {
                        Text("本地终端").tag(SSHSessionKind.local)
                        Text("远程 SSH").tag(SSHSessionKind.remote)
                    }
                    .pickerStyle(.segmented)
                }

                TextField("名称", text: $draft.name,
                          prompt: Text(draft.isLocal ? "例如 前端项目" : "例如 生产服务器"))

                if draft.isLocal {
                    localSection
                } else {
                    remoteSection
                }
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
                Button(draft.isLocal ? "保存并打开" : "保存并连接") { save(connect: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let forcedKind { draft.kind = forcedKind }
            keyDisplay = draft.privateKeyFileName != nil ? "已配置私钥" : "未选择"
        }
    }

    private var title: String {
        if isNew { return "新建记录" }
        return draft.isLocal ? "编辑本地终端" : "编辑 SSH 连接"
    }

    // MARK: - 分区

    /// 本地终端：只需要「默认进入的文件夹」。
    @ViewBuilder
    private var localSection: some View {
        HStack {
            TextField("工作目录", text: workingDirectoryBinding,
                      prompt: Text("留空则进入个人目录"))
            Button("选择…") { pickDirectory() }
        }
        Text("打开这条记录时，本地 shell 会直接以该目录作为起始位置。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// 远程 SSH：主机信息 + 认证 + 可选的远端默认目录。
    @ViewBuilder
    private var remoteSection: some View {
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

        TextField("默认目录（远端）", text: workingDirectoryBinding,
                  prompt: Text("/var/www（可留空）"))
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

    /// 默认目录字段：空串回写为 nil，便于用 `normalizedWorkingDirectory` 统一判断。
    private var workingDirectoryBinding: Binding<String> {
        Binding(
            get: { draft.workingDirectory ?? "" },
            set: { draft.workingDirectory = $0.isEmpty ? nil : $0 }
        )
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

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择目录"
        if let current = draft.normalizedWorkingDirectory {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.workingDirectory = url.path
    }

    private func save(connect: Bool) {
        errorMessage = nil
        draft.host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.workingDirectory = draft.normalizedWorkingDirectory

        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            if draft.isLocal {
                // 本地记录用目录名兜底，避免出现一堆「未命名」。
                let last = draft.normalizedWorkingDirectory.map { ($0 as NSString).lastPathComponent }
                draft.name = (last?.isEmpty == false ? last! : "本地终端")
            } else {
                draft.name = draft.host
            }
        }

        // 本地终端：只有名称是必需项，目录留空即进个人目录。
        if draft.isLocal {
            persist(connect: connect)
            return
        }

        guard !draft.host.isEmpty, !draft.username.isEmpty else {
            errorMessage = "主机与用户名不能为空"
            return
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

        persist(connect: connect)
    }

    private func persist(connect: Bool) {
        do {
            try SSHProfileStore.save(draft)
            dismiss()
            onSaved(draft, connect)
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}
