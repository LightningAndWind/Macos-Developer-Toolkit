//
//  SFTPProfilePicker.swift
//  devkit
//
//  M6：为 SFTP 某一侧选择 SSH 连接的弹窗。复用 SSH 终端的连接配置库
//  （SSHProfileStore）与编辑器（SSHProfileEditorView）：可新建、编辑、删除连接，
//  点一行即向该侧发起 SFTP 连接（后台进行，结果反馈在面板上）。
//

import SwiftUI

struct SFTPProfilePicker: View {
    let side: SFTPSideState
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [SSHProfile] = []
    @State private var editing: SSHProfile?
    @State private var editingIsNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("为\(side.side == .left ? "左" : "右")侧选择 SSH 连接")
                    .font(.headline)
                Spacer()
                Button {
                    editingIsNew = true
                    editing = SSHProfile(folderID: nil, name: "", host: "",
                                         port: SSHProfile.defaultPort, username: "", authKind: .password)
                } label: {
                    Label("新建连接", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if profiles.isEmpty {
                VStack(spacing: 8) {
                    Text("还没有已保存的 SSH 连接")
                        .foregroundStyle(.secondary)
                    Text("点击右上角「新建连接」创建一条，或先在「SSH 终端」工具中添加。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(profiles) { profile in
                        row(profile)
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 420, height: 360)
        .onAppear { refresh() }
        .sheet(item: $editing) { profile in
            SSHProfileEditorView(draft: profile, isNew: editingIsNew) { saved, connect in
                refresh()
                if connect { connectSide(saved) }
            }
        }
    }

    private func row(_ profile: SSHProfile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: profile.authKind == .password ? "key.horizontal" : "seal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name.isEmpty ? profile.host : profile.name)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(profile.username)@\(profile.host):\(profile.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("连接") { connectSide(profile) }
                .controlSize(.small)
            // 右键 / 悬停编辑与删除
            Menu {
                Button("编辑…") {
                    editingIsNew = false
                    editing = profile
                }
                Button("删除", role: .destructive) {
                    SSHProfileStore.delete(profile.id)
                    refresh()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .contentShape(Rectangle())
        .onTapGesture { connectSide(profile) }
    }

    private func refresh() {
        profiles = SSHProfileStore.allRequests()
    }

    /// 连接在后台进行：弹窗关闭，连接中/失败/成功状态显示在对应面板上。
    private func connectSide(_ profile: SSHProfile) {
        dismiss()
        Task { await side.connect(to: profile) }
    }
}
