//
//  HTTPToolView.swift
//  devkit
//
//  M2：HTTP 工具根视图 —— 顶部请求栏 + 下方"请求配置 / 响应"上下分区。
//

import AppKit
import SwiftUI

struct HTTPToolView: View {
    @Bindable var tool: HTTPTool
    @Environment(AppState.self) private var appState
    @FocusState private var urlFocused: Bool

    /// 请求编辑区占上下可用高度的比例；拖拽分隔线调整，双击回到 0.5。以比例而非固定高度存储，
    /// 使窗口缩放时两区按同比例分配，不会出现某一区被完全挤没。
    @State private var editorRatio: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 0) {
            requestBar
                // 方法下拉需要盖住下方编辑区，把请求栏抬到同层最上。
                .zIndex(1)
            Divider()
            splitPanes
        }
        .background(.ultraThinMaterial)
        .task { tool.ensureHistoryLoaded() }
        // 编辑任意请求内容（URL/方法/Params/Headers/Body/Auth 均属 request）后防抖落盘，
        // 避免仅靠 scenePhase/退出钩子在强杀或开发重编译时丢最新状态。
        .onChange(of: tool.request) { _, _ in appState.scheduleSessionSave() }
    }

    /// 上（请求编辑）下（响应）可拖拽调节高度的分区。
    private var splitPanes: some View {
        GeometryReader { proxy in
            let minPane = Theme.Metrics.httpPaneMinHeight
            let total = max(proxy.size.height, minPane * 2)
            let defaultEditor = total * 0.5
            // 上区高度：按比例的期望值限幅到 [min, total - min]，保证两区都留最小可见高度。
            let editorHeight = min(max(total * editorRatio, minPane), total - minPane)
            let responseHeight = max(minPane, total - editorHeight - 1)

            VStack(spacing: 0) {
                RequestEditorView(tool: tool)
                    .frame(height: editorHeight)
                HeightResizeDivider(
                    height: Binding(
                        get: { editorHeight },
                        set: { editorRatio = $0 / total }
                    ),
                    range: minPane...(total - minPane),
                    defaultHeight: defaultEditor
                )
                ResponseViewerView(tool: tool)
                    .frame(height: responseHeight)
            }
        }
    }

    // MARK: - 顶部请求栏

    private var requestBar: some View {
        HStack(spacing: 10) {
            HTTPMethodPicker(method: $tool.request.method)

            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                TextField("https://api.example.com/v1/resource", text: $tool.request.urlString)
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .focused($urlFocused)
                    .onSubmit { Task { await tool.send() } }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.10))
                    )
            )

            sendButton

            Menu {
                Button {
                    copyCURL()
                } label: {
                    Label("复制为 cURL", systemImage: "doc.on.doc")
                }
                .disabled(tool.request.isEmpty)

                Divider()

                Button(role: .destructive) {
                    tool.resetRequest()
                } label: {
                    Label("清空请求", systemImage: "trash")
                }
                .disabled(tool.request.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            // borderlessButton 会额外画一个下拉箭头，与图标抢视觉；只留图标。
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var sendButton: some View {
        Button {
            urlFocused = false
            Task { await tool.send() }
        } label: {
            HStack(spacing: 5) {
                if tool.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
                Text(tool.isLoading ? "发送中" : "发送")
            }
            .frame(minWidth: 72)
        }
        .keyboardShortcut(.return, modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(tool.request.isEmpty || tool.isLoading)
    }

    private func copyCURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tool.curlCommand(), forType: .string)
    }
}
