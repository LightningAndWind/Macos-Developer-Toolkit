//
//  HistoryListView.swift
//  devkit
//
//  M2：历史记录列表 —— 搜索、点击查看详情、载入重发、删除、清空。
//

import SwiftUI

struct HistoryListView: View {
    @Bindable var tool: HTTPTool
    @State private var search: String = ""
    @State private var detailRecord: HTTPHistoryRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索 历史（URL / 方法）", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))

                Button(role: .destructive) {
                    tool.clearHistory()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(tool.history.isEmpty)
                .help("清空全部历史")
            }

            if tool.history.isEmpty {
                ContentUnavailableView(
                    "暂无历史",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("发送请求后会自动记录在这里。")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(tool.history) { record in
                            HistoryRow(record: record)
                                .contentShape(Rectangle())
                                .onTapGesture { detailRecord = record }
                                .contextMenu {
                                    Button("查看详情") { detailRecord = record }
                                    Button("载入到编辑器") { tool.applyHistory(record) }
                                    Button("删除", role: .destructive) { tool.deleteHistory(record) }
                                }
                        }
                    }
                }
            }
        }
        .sheet(item: $detailRecord) { record in
            HistoryDetailView(record: record) { tool.applyHistory(record) }
        }
        .onChange(of: search) { _, newValue in
            tool.refreshHistory(query: newValue)
        }
    }
}

/// 单条历史行。
private struct HistoryRow: View {
    let record: HTTPHistoryRecord

    private var methodColor: Color { HTTPDisplay.color(forMethod: record.method) }

    private var statusColor: Color {
        guard let code = record.statusCode else { return .secondary }
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500...: return .red
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(record.method.uppercased())
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(methodColor)
                .frame(width: 56, alignment: .leading)

            Text(record.url)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if let code = record.statusCode {
                Text("\(code)")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(statusColor)
            } else {
                Text("失败")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(HTTPDisplay.historyTimestamp(record.timestamp))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
    }
}
