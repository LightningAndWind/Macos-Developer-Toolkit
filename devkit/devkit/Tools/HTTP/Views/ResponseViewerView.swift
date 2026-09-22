//
//  ResponseViewerView.swift
//  devkit
//
//  M2：响应展示区 —— 状态码/耗时/大小 + Pretty / Raw / Headers / Preview 视图。
//

import AppKit
import SwiftUI
import WebKit

struct ResponseViewerView: View {
    @Bindable var tool: HTTPTool

    private enum Tab: String, CaseIterable, Identifiable {
        case pretty = "Pretty"
        case raw = "Raw"
        case headers = "Headers"
        case preview = "Preview"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .pretty

    /// 数据栏复制按钮的瞬时反馈（状态栏不再重复提供复制）。
    @State private var contentCopied = false
    /// 代际号：避免连续复制时旧任务提前清除新一次的反馈。
    @State private var contentCopyGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            if let error = tool.errorMessage {
                errorBanner(error)
            }

            if let response = tool.response {
            statusBar(response)
            if response.isBodyTruncated {
                truncationBanner(response)
            }
            Divider()
            content(response)
            } else if tool.isLoading {
                loadingState
            } else {
                emptyState
            }
        }
    }

    // MARK: - 状态条

    private func statusBar(_ response: HTTPResponseModel) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(HTTPDisplay.color(for: response.statusCategory))
                    .frame(width: 8, height: 8)
                Text("\(response.statusCode)")
                    .font(.body.monospaced().weight(.semibold))
                Text(response.statusCategory.label)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Label(HTTPDisplay.duration(response.durationMs), systemImage: "clock")
            Label(sizeText(response), systemImage: "internaldrive")

            if let ct = response.contentType {
                Text(ct)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 大小文案。被截断时实际长度未知，加「≥」前缀 ——
    /// 直接显示 10 MB 会让人以为服务器只返回了 10 MB。
    private func sizeText(_ response: HTTPResponseModel) -> String {
        (response.isBodyTruncated ? "≥ " : "") + HTTPDisplay.size(response.sizeBytes)
    }

    /// 响应体被截断时的说明条。
    ///
    /// 必须显式告知，否则用户会以为「响应就是这么短」—— 尤其是接口出问题时，
    /// 看到被截断的报错 JSON 尾部缺失，很容易误判成服务端返回不完整。
    private func truncationBanner(_ response: HTTPResponseModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors")
            Text("响应体超过 \(HTTPDisplay.size(HTTPClient.maxBodyBytes)) 上限，已中止接收，仅保留并显示前 \(HTTPDisplay.size(response.sizeBytes))。如需完整内容请用 curl 导出后在终端查看。")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - 内容

    private func content(_ response: HTTPResponseModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("视图", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .pointingHandOnHover()

                Spacer()

                // 复制当前可见的文本内容（Pretty / Raw）；Headers / Preview 不适用。
                if tab == .pretty || tab == .raw {
                    Button {
                        copyVisibleContent(response)
                    } label: {
                        Label(contentCopied ? "复制成功" : "复制", systemImage: contentCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(contentCopied ? Color.green : Color.primary)
                    .help("复制当前视图内容")
                    .pointingHandOnHover()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch tab {
                case .pretty:  prettyView(response)
                case .raw:     rawView(response)
                case .headers: headersView(response)
                case .preview: previewView(response)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func prettyView(_ response: HTTPResponseModel) -> some View {
        if let json = response.prettyJSON {
            selectableCode(json)
        } else if let text = response.bodyText {
            selectableCode(text)
        } else {
            binaryHint(response)
        }
    }

    @ViewBuilder
    private func rawView(_ response: HTTPResponseModel) -> some View {
        if let text = response.bodyText {
            selectableCode(text)
        } else {
            binaryHint(response)
        }
    }

    private func headersView(_ response: HTTPResponseModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(response.headers.enumerated()), id: \.offset) { _, header in
                    HStack(alignment: .top, spacing: 10) {
                        Text(header.key)
                            .font(.body.monospaced().weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 180, alignment: .leading)
                        Text(header.value)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func previewView(_ response: HTTPResponseModel) -> some View {
        if response.isHTML {
            HTMLPreview(html: response.bodyText ?? "")
        } else if response.isImage, let image = NSImage(data: response.bodyData) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(12)
        } else {
            ContentUnavailableView(
                "无法预览",
                systemImage: "eye.slash",
                description: Text("Preview 仅支持 HTML 与图片响应。")
            )
        }
    }

    // MARK: - 辅助视图

    private func selectableCode(_ text: String) -> some View {
        // ScrollView 默认把比视口窄的内容居中。用 GeometryReader 拿到视口尺寸，
        // 给文本容器一个 >= 视口的 minWidth/minHeight 并锁 .topLeading：
        // 窄内容靠左上，宽内容仍可横向滚动。
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(minWidth: geo.size.width, maxWidth: .infinity,
                           minHeight: geo.size.height, alignment: .topLeading)
            }
        }
    }

    private func binaryHint(_ response: HTTPResponseModel) -> some View {
        ContentUnavailableView(
            "二进制内容",
            systemImage: "doc.zipper",
            description: Text("响应体无法以文本显示（\(sizeText(response))）。")
        )
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("正在发送请求…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "尚未发送请求",
            systemImage: "arrow.up.arrow.down.square",
            description: Text("填写地址后点“发送”或按 ⌘↵。")
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.callout)
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(10)
        .background(Color.red.opacity(0.10))
    }

    /// 数据栏复制按钮的瞬时反馈，约 1.4s 后自动复原。
    private func flashContentCopied() {
        contentCopyGeneration += 1
        let generation = contentCopyGeneration
        contentCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if generation == contentCopyGeneration { contentCopied = false }
        }
    }

    /// 复制当前标签页可见的文本：Pretty 优先复制格式化 JSON，Raw 复制原始体。
    private func copyVisibleContent(_ response: HTTPResponseModel) {
        let text: String?
        switch tab {
        case .pretty: text = response.prettyJSON ?? response.bodyText
        case .raw:    text = response.bodyText
        default:      text = nil
        }
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashContentCopied()
    }
}

/// WKWebView 包装，用于 HTML Preview。
private struct HTMLPreview: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            nsView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML: String?
    }
}
