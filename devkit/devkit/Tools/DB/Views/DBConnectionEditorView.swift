//
//  DBConnectionEditorView.swift
//  devkit
//
//  数据库连接编辑器（sheet）：名称 / 类型 / 主机 / 端口 / 用户名 / 密码 / 默认库。
//  类型切换时端口联动默认值（3306 / 6379）。对照 SSHProfileEditorView 的 draft + 回调形态。
//

import SwiftUI

struct DBConnectionEditorView: View {
    /// 编辑草稿（新建时传空白模型）。
    @State var draft: DBConnection
    let isNew: Bool
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    private var isMySQL: Bool { draft.kind == .mysql }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            Form {
                Section {
                    TextField("名称", text: $draft.name)
                    Picker("类型", selection: $draft.kind) {
                        ForEach(DBConnectionKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draft.kind) { oldValue, newValue in
                        // 端口为空或仍等于旧类型默认值时联动，避免覆盖用户自定义端口。
                        if draft.port == 0 || draft.port == oldValue.defaultPort {
                            draft.port = newValue.defaultPort
                        }
                    }
                } header: {
                    Text("基本信息")
                }

                Section {
                    TextField("主机", text: $draft.host)
                        .font(.system(size: 13, design: .monospaced))
                    TextField("端口", value: $draft.port, format: .number.grouping(.never))
                        .font(.system(size: 13, design: .monospaced))
                } header: {
                    Text("服务器")
                }

                Section {
                    if isMySQL {
                        TextField("用户名（如 root）", text: usernameBinding)
                        SecureField("密码（可空）", text: passwordBinding)
                        TextField("默认数据库（可空）", text: databaseBinding)
                    } else {
                        TextField("用户名（Redis 6+ ACL，可空）", text: usernameBinding)
                        SecureField("密码（requirepass，可空）", text: passwordBinding)
                        TextField("默认 db 序号（0-15，可空）", text: databaseBinding)
                    }
                } header: {
                    Text(isMySQL ? "认证与数据库" : "认证")
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("保存") { save() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
            }
        }
        .frame(width: 420, height: 430)
    }

    private var titleBar: some View {
        HStack {
            Text(isNew ? "新建数据库连接" : "编辑数据库连接")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 可空字段绑定（空串 ↔ nil）

    private var usernameBinding: Binding<String> {
        Binding(get: { draft.username ?? "" },
                set: { draft.username = $0.isEmpty ? nil : $0 })
    }

    private var passwordBinding: Binding<String> {
        Binding(get: { draft.password ?? "" },
                set: { draft.password = $0.isEmpty ? nil : $0 })
    }

    private var databaseBinding: Binding<String> {
        Binding(get: { draft.database ?? "" },
                set: { draft.database = $0.isEmpty ? nil : $0 })
    }

    // MARK: - 保存

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "请填写名称"
            return
        }
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            errorMessage = "请填写主机"
            return
        }
        guard (1...65535).contains(draft.port) else {
            errorMessage = "端口需在 1-65535 之间"
            return
        }
        if isMySQL, usernameBinding.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty {
            errorMessage = "MySQL 需要用户名"
            return
        }
        if !isMySQL, let db = draft.normalizedDatabase, Int(db) == nil {
            errorMessage = "Redis 的 db 需为数字（如 0）"
            return
        }

        var stored = draft
        stored.name = name
        stored.host = host
        do {
            try DBConnectionStore.save(stored)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
