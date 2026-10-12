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

    /// 超时设置气泡。
    @State private var showsTimeoutPopover = false

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
                    .onSubmit { tool.send() }
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

            timeoutChip

            if tool.isLoading {
                stopButton
            } else {
                sendButton
            }

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
            .pointingHandOnHover()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var sendButton: some View {
        Button {
            urlFocused = false
            tool.send()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "paperplane.fill")
                Text("发送")
            }
            .frame(minWidth: 72)
        }
        .keyboardShortcut(.return, modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(tool.request.isEmpty)
        .pointingHandOnHover()
    }

    /// 发送中顶掉发送按钮。
    ///
    /// 超时上限放开到 1 小时后，没有它用户就只能干等：请求在途时连关标签都得等它自己超时。
    /// 与发送按钮同为 `minWidth: 72`，互换时不会让请求栏跳动。
    private var stopButton: some View {
        Button {
            tool.cancelSend()
        } label: {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("停止")
            }
            .frame(minWidth: 72)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .pointingHandOnHover()
        .help("中断在途请求")
    }

    // MARK: - 超时

    /// 超时档位控件。放在请求栏而不是编辑器分区里 —— 它和「发送」属于同一件事的上下文，
    /// 要调的时候人正好盯着这一行，不必先切分区。
    private var timeoutChip: some View {
        Button {
            showsTimeoutPopover = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text(HTTPDisplay.timeoutLabel(tool.request.timeoutSeconds))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.10))
                    )
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .pointingHandOnHover()
        .help("请求超时（空闲超时）：等待下一段响应数据的最长时间")
        .popover(isPresented: $showsTimeoutPopover, arrowEdge: .bottom) {
            timeoutPopover
        }
    }

    private var timeoutPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HTTPSection(title: "常用档位") {
                HStack(spacing: 6) {
                    ForEach(HTTPRequestModel.timeoutPresets, id: \.self) { seconds in
                        if tool.request.timeoutSeconds == seconds {
                            Button(HTTPDisplay.timeoutLabel(seconds)) { tool.request.timeoutSeconds = seconds }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        } else {
                            Button(HTTPDisplay.timeoutLabel(seconds)) { tool.request.timeoutSeconds = seconds }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }

            HTTPSection(title: "自定义") {
                HStack(spacing: 6) {
                    TextField("", value: $tool.request.timeoutSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    Text("秒")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Stepper("",
                            value: $tool.request.timeoutSeconds,
                            in: HTTPRequestModel.minTimeoutSeconds...HTTPRequestModel.maxTimeoutSeconds)
                        .labelsHidden()
                }
            }

            Divider()

            Text("**空闲超时**，不是总时长：每收到一段响应数据就重新计时。流式（SSE）接口只要相邻两块间隔不超过该值就不会触发；非流式接口必须能等完整个生成过程 —— 长耗时 LLM 生成建议设 120 秒以上。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300)
        }
        .padding(14)
    }

    private func copyCURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tool.curlCommand(), forType: .string)
    }
}
