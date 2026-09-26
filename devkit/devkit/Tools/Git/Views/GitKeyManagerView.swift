//
//  GitKeyManagerView.swift
//  devkit
//
//  密钥（对）管理：生成新密钥（ed25519 默认 / RSA）、导入已有私钥、复制公钥到剪贴板、预览、删除。
//  密钥对落进数据目录 git_keys/，GitKeyStore 管记录。把数据目录放到同步盘即可跨设备复用。
//

import AppKit
import SwiftUI

struct GitKeyManagerView: View {
    @Environment(\.dismiss) private var dismiss
    /// 密钥增删后回调（供调用方刷新绑定列表）。
    var onChanged: () -> Void = {}
    @State private var keys: [GitKey] = []
    @State private var generating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("密钥管理").font(.headline)
                Spacer()
                Button {
                    generating = true
                } label: {
                    Label("生成密钥", systemImage: "plus")
                }
                .controlSize(.small)
                Button {
                    importKey()
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
            }

            Text("公钥复制到 GitHub / GitLab；私钥留在应用数据目录 git_keys/。把数据目录放到同步盘即可跨设备复用同一对密钥。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if keys.isEmpty {
                ContentUnavailableCompat(text: "还没有密钥",
                                         sub: "点击「生成密钥」创建一对新的 SSH 密钥。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(keys) { key in row(key) }
                    }
                    .padding(4)
                }
                .scrollIndicators(.never)
                .scrollIndicatorBar()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560, height: 460)
        .onAppear { refresh() }
        .sheet(isPresented: $generating) {
            GitKeyGenerateSheet { refresh() }
        }
    }

    private func row(_ key: GitKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(.tint)
                Text(key.name).font(.system(size: 13, weight: .semibold))
                badge(key.algorithm.label)
                if key.imported { badge("导入") }
                if key.hasPassphrase { badge("口令保护") }
                Spacer()
                Button("复制公钥") { copyPublicKey(key) }
                    .controlSize(.small)
                Menu {
                    Button("在访达中显示私钥") { reveal(key) }
                    Divider()
                    Button("删除", role: .destructive) { delete(key) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
            }
            Text(key.privateFileName == nil ? "私钥文件缺失" : key.fingerprintHint)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            // 公钥全文预览（可滚动选择复制）。
            ScrollView {
                Text(key.publicKey.isEmpty ? "（无公钥文本，可能是带口令的导入密钥）" : key.publicKey)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 46)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.5)))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func refresh() {
        keys = GitKeyStore.all()
        onChanged()
    }

    private func copyPublicKey(_ key: GitKey) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(key.publicKey, forType: .string)
    }

    private func reveal(_ key: GitKey) {
        guard let fileName = key.privateFileName,
              let url = GitKeyStorage.resolvedPrivateURL(fileName: fileName) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func delete(_ key: GitKey) {
        GitKeyStore.delete(id: key.id)
        refresh()
    }

    private func importKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导入私钥"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        errorMessage = nil
        Task {
            do {
                let key = try await GitKeyStorage.importKey(from: url, name: url.lastPathComponent)
                try GitKeyStore.save(key)
                refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// 生成密钥抽屉。
struct GitKeyGenerateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void

    @State private var name = ""
    @State private var algorithm: GitKeyAlgorithm = .ed25519
    @State private var comment = ""
    @State private var usePassphrase = false
    @State private var passphrase = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("生成 SSH 密钥对").font(.headline)
            Form {
                TextField("名称", text: $name, prompt: Text("例如 工作 GitHub"))
                Picker("算法", selection: $algorithm) {
                    ForEach(GitKeyAlgorithm.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("注释（邮箱 / 用途）", text: $comment, prompt: Text("you@example.com"))
                Toggle("为私钥设置口令", isOn: $usePassphrase)
                if usePassphrase {
                    SecureField("口令", text: $passphrase)
                }
            }
            .formStyle(.grouped)

            Text("生成后请把公钥添加到 GitHub / GitLab。私钥仅存于应用数据目录。")
                .font(.caption).foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button {
                    create()
                } label: {
                    if working {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("生成中…") }
                    } else {
                        Text("生成")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        errorMessage = nil
        working = true
        let pass = usePassphrase ? passphrase : ""
        Task {
            defer { working = false }
            do {
                let key = try await GitKeyStorage.generate(name: name, algorithm: algorithm,
                                                           comment: comment, passphrase: pass)
                try GitKeyStore.save(key)
                dismiss()
                onCreated()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// macOS 14 的 ContentUnavailableView 语义的最小兼容替代（避免依赖较高系统版本 API）。
private struct ContentUnavailableCompat: View {
    let text: String
    let sub: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Text(sub).font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
