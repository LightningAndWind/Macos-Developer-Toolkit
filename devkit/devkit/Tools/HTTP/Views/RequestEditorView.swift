//
//  RequestEditorView.swift
//  devkit
//
//  M2：请求配置区 —— Params / Headers / Body / Auth / History 分区编辑。
//

import SwiftUI

struct RequestEditorView: View {
    @Bindable var tool: HTTPTool

    private enum Section: String, CaseIterable, Identifiable {
        case params = "Params"
        case headers = "Headers"
        case body = "Body"
        case auth = "Auth"
        case history = "历史"
        var id: String { rawValue }
    }

    @State private var section: Section = .params

    var body: some View {
        VStack(spacing: 0) {
            Picker("分区", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                Group {
                    switch section {
                    case .params:  paramsPane
                    case .headers: headersPane
                    case .body:    bodyPane
                    case .auth:    authPane
                    case .history: HistoryListView(tool: tool)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
    }

    // MARK: - Params

    private var paramsPane: some View {
        HTTPKVEditor(
            items: $tool.request.params,
            keyPlaceholder: "参数名",
            valuePlaceholder: "参数值",
            showsEnabledToggle: true,
            footerActions: AnyView(
                Button {
                    tool.request.syncQueryToParams()
                } label: {
                    Label("从 URL 解析", systemImage: "arrow.down.doc")
                }
            )
        )
    }

    // MARK: - Headers

    private var headersPane: some View {
        HTTPKVEditor(
            items: $tool.request.headers,
            keyPlaceholder: "Header",
            valuePlaceholder: "值",
            showsEnabledToggle: true
        )
    }

    // MARK: - Body

    private var bodyPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("类型", selection: $tool.request.body.kind) {
                ForEach(HTTPBodyModel.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tool.request.body.kind {
            case .none:
                Text("该请求不含 Body。")
                    .font(.callout).foregroundStyle(.secondary)
            case .form:
                HTTPKVEditor(items: $tool.request.body.formFields,
                             keyPlaceholder: "字段", valuePlaceholder: "值")
            case .json, .raw:
                if tool.request.body.kind == .json {
                    Button {
                        formatJSON()
                    } label: {
                        Label("格式化 JSON", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                TextEditor(text: $tool.request.body.text)
                    .font(.body.monospaced())
                    .frame(minHeight: 140)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10)))
            }
        }
    }

    private func formatJSON() {
        guard let data = tool.request.body.text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8)
        else { return }
        tool.request.body.text = string
    }

    // MARK: - Auth

    private var authPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("方式", selection: $tool.request.auth.kind) {
                ForEach(HTTPAuthModel.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tool.request.auth.kind {
            case .none:
                Text("不发送 Authorization 头。")
                    .font(.callout).foregroundStyle(.secondary)
            case .bearer:
                HTTPSection(title: "Token") {
                    TextField("访问令牌", text: $tool.request.auth.token)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
            case .basic:
                HTTPSection(title: "用户名") {
                    TextField("username", text: $tool.request.auth.username)
                        .textFieldStyle(.roundedBorder)
                }
                HTTPSection(title: "密码") {
                    SecureField("password", text: $tool.request.auth.password)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let preview = tool.request.auth.headerValue {
                Text("将发送：Authorization: \(preview.prefix(24))…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
