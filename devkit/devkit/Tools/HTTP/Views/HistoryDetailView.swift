//
//  HistoryDetailView.swift
//  devkit
//
//  M2：历史记录详情弹窗 —— 分“请求 / 响应”两页展示某次交互的入参、请求头、Body、
//  认证，以及响应的状态/耗时/大小、响应头与响应体。
//  旧记录或未收到响应时，响应页提示仅有摘要。
//

import SwiftUI

struct HistoryDetailView: View {
    let record: HTTPHistoryRecord
    /// 载入到当前编辑器（关窗前触发）。
    var onLoad: () -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Pane: String, CaseIterable, Identifiable {
        case request = "请求"
        case response = "响应"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .request

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("页", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ScrollView {
                Group {
                    switch pane {
                    case .request:  requestPane
                    case .response: responsePane
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
    }

    // MARK: - 顶部概览

    private var header: some View {
        HStack(spacing: 10) {
            Text(record.method.uppercased())
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(HTTPDisplay.color(forMethod: record.method))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(HTTPDisplay.color(forMethod: record.method).opacity(0.14)))

            Text(record.url)
                .font(.callout.monospaced())
                .lineLimit(2)
                .textSelection(.enabled)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            statusPill
        }
        .padding(16)
    }

    private var statusPill: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let code = record.statusCode {
                Text("\(code)")
                    .font(.body.monospaced().weight(.semibold))
                    .foregroundStyle(statusColor(code))
            } else {
                Text("失败")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(HTTPDisplay.fullTimestamp(record.timestamp))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500...: return .red
        default: return .secondary
        }
    }

    // MARK: - 各分区

    private var requestPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paramsSection
            headersSection
            bodySection
            authSection
        }
    }

    private var paramsSection: some View {
        HTTPSection(title: "入参 (Params)") {
            ReadOnlyKVList(items: record.request.params)
        }
    }

    private var headersSection: some View {
        HTTPSection(title: "请求头 (Headers)") {
            ReadOnlyKVList(items: record.request.headers)
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        let body = record.request.body
        if body.kind == .none {
            HTTPSection(title: "Body") {
                Text("该请求不含 Body。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            HTTPSection(title: "Body · \(body.kind.rawValue)") {
                switch body.kind {
                case .form:
                    ReadOnlyKVList(items: body.formFields)
                case .json, .raw:
                    SelectableCodeBlock(text: body.text)
                case .none:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var authSection: some View {
        let auth = record.request.auth
        HTTPSection(title: "认证 (Auth)") {
            if auth.kind == .none {
                Text("不发送 Authorization 头。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(auth.kind.rawValue)
                        .font(.callout.weight(.medium))
                    if let preview = auth.headerValue {
                        Text("Authorization: \(preview.prefix(32))…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var responsePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HTTPSection(title: "概览") {
                HStack(spacing: 18) {
                    metric("状态", value: record.statusCode == nil ? "—" : String(record.statusCode ?? 0))
                    metric("耗时", value: record.durationMs == nil ? "—" : HTTPDisplay.duration(record.durationMs ?? 0))
                    metric("大小", value: record.sizeBytes == nil ? "—" : HTTPDisplay.size(record.sizeBytes ?? 0))
                }
            }

            if let snapshot = record.response {
                HTTPSection(title: "响应头 (Headers)") {
                    ReadOnlyKVList(items: snapshot.headers)
                }
                HTTPSection(title: "响应体 (Body)" + (snapshot.isBodyTruncated ? " · 已截断" : "")) {
                    responseBodyView(snapshot)
                    if snapshot.isBodyTruncated {
                        Text("响应体较大，仅保存前 \(HTTPDisplay.size(HTTPHistoryStore.maxBodyBytes))；如需完整内容请重新发送。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("该记录未保存响应体与响应头（旧版本历史或请求未成功）。点“载入到编辑器”后重新发送即可查看。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func responseBodyView(_ snapshot: HTTPResponseSnapshot) -> some View {
        if let json = snapshot.prettyJSON {
            SelectableCodeBlock(text: json)
        } else if let text = snapshot.bodyText {
            SelectableCodeBlock(text: text)
        } else {
            Text("响应体为二进制内容（\(HTTPDisplay.size(snapshot.sizeBytes))），无法以文本显示。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced().weight(.semibold))
        }
    }

    // MARK: - 底部操作

    private var footer: some View {
        HStack(spacing: 8) {
            Button("载入到编辑器") {
                onLoad()
                dismiss()
            }
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}

// MARK: - 只读展示组件

/// 只读键值列表：历史详情复用，禁用行不代表删除，灰色显示被禁用项。
private struct ReadOnlyKVList: View {
    let items: [HTTPKV]

    var body: some View {
        let visible = items.filter { !$0.isPlaceholder }
        if visible.isEmpty {
            Text("无").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text(item.key)
                            .font(.body.monospaced().weight(.semibold))
                            .foregroundStyle(item.enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .frame(width: 160, alignment: .leading)
                        Text(item.value)
                            .font(.body.monospaced())
                            .foregroundStyle(item.enabled ? .primary : .secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 5)
                    if item != visible.last {
                        Divider().opacity(0.5)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.5)))
        }
    }
}

/// 可选中、可横向滚动的代码块（Body 文本）。
private struct SelectableCodeBlock: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text.isEmpty ? "无" : text)
                .font(.body.monospaced())
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: 160)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.5)))
    }
}
