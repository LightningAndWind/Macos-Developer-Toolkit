//
//  OnboardingView.swift
//  devkit
//
//  首次启动引导：强制选择数据存储目录，未选前无法进入主界面。
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedDirectory: URL?
    @State private var errorMessage: String?
    @State private var isConfirming: Bool = false

    var body: some View {
        ZStack {
            // 毛玻璃背景
            VisualEffectBackground()
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.accentColor.opacity(0.18), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                header
                content
                footer
            }
            .padding(60)
            .frame(maxWidth: 720)
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "swissarmyknife")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.tint)
            Text("欢迎使用 devkit")
                .font(.largeTitle.weight(.semibold))
            Text("macOS 原生开发者工具箱 · 精简、快速")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("数据存储目录", systemImage: "folder.badge.gearshape")
                        .font(.headline)
                    Text("devkit 会将 SQLite 数据库文件放在你选择的目录，用于保存：HTTP 历史与集合、环境变量、SSH Profiles 元数据、会话与标签分组状态、JSON 文档草稿。所有数据仅保存在本地。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    directoryPicker

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .transition(.opacity)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.tint)
                Text("目录权限：devkit 只在你选择的目录内创建/读写 `devkit.sqlite3`，不会访问其他位置。可在设置中随时更换目录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    private var directoryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                if let selectedDirectory {
                    Text(selectedDirectory.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("尚未选择目录")
                        .foregroundStyle(.secondary)
                        .italic()
                }
                Spacer()
                Button {
                    pickDirectory()
                } label: {
                    Text(selectedDirectory == nil ? "选择目录…" : "更换…")
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button {
                confirm()
            } label: {
                Text("进入 devkit")
                    .frame(minWidth: 140)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedDirectory == nil || isConfirming)
        }
    }

    // MARK: - Actions

    private func pickDirectory() {
        guard let url = PanelHelpers.chooseDirectory(title: "选择 devkit 数据存储目录") else { return }
        selectedDirectory = url
        errorMessage = nil
    }

    private func confirm() {
        guard let dir = selectedDirectory else { return }
        isConfirming = true
        errorMessage = nil
        // 校验可写
        let probe = dir.appendingPathComponent(".devkit-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .atomic)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            errorMessage = "目录不可写，请重新选择"
            isConfirming = false
            return
        }
        appState.completeOnboarding(with: dir)
        isConfirming = false
    }
}

/// 使用 NSVisualEffectView 提供原生毛玻璃背景。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

#Preview {
    OnboardingView()
        .environment(AppState.shared)
        .frame(width: 900, height: 620)
}
