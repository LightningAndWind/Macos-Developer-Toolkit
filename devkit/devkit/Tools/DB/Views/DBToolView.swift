//
//  DBToolView.swift
//  devkit
//
//  数据库工具视图：顶栏连接选择与管理，中部输出区，底部命令输入（⌘↩ 执行）。
//  布局对照 SSH / Git 工具的顶栏 + 内容区习惯；输出按方向着色（输入灰、结果正常、错误红、提示次级）。
//

import SwiftUI

struct DBToolView: View {
    @Bindable var tool: DBTool
    @State private var editingConnection: DBConnection?
    @State private var editingIsNew = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            outputArea
            Divider()
            inputArea
        }
        .onAppear { tool.refreshConnections() }
        .sheet(item: $editingConnection) { draft in
            DBConnectionEditorView(draft: draft, isNew: editingIsNew) {
                tool.refreshConnections()
            }
        }
    }

    // MARK: - 顶栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                if tool.connections.isEmpty {
                    Text("暂无连接").font(.caption)
                }
                ForEach(tool.connections) { connection in
                    Button {
                        tool.selectedConnectionID = connection.id
                    } label: {
                        HStack {
                            Text(connection.name)
                            Spacer()
                            Text(connection.kind.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tool.selectedConnection?.kind == .redis ? "bolt.horizontal.circle" : "cylinder.and.ellipse")
                        .font(.system(size: 11))
                    Text(tool.selectedConnection?.name ?? "选择连接")
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
            .fixedSize()

            Text(tool.selectedConnection?.displaySummary ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                editingIsNew = false
                editingConnection = tool.selectedConnection
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .disabled(tool.selectedConnection == nil)
            .help("编辑当前连接")

            Button {
                editingIsNew = true
                editingConnection = DBConnection(name: "新连接")
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("新建连接")

            Button {
                tool.clearOutput()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .disabled(tool.output.isEmpty)
            .help("清空输出")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 输出区

    private var outputArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if tool.output.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "terminal")
                                .font(.system(size: 26))
                                .foregroundStyle(.tertiary)
                            Text(tool.connections.isEmpty
                                 ? "先新建一条 MySQL / Redis 连接，然后在下方输入 SQL 或命令执行。"
                                 : "在下方输入 SQL（MySQL）或 Redis 命令（每行一条），按 ⌘↩ 执行。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.top, 60)
                    }
                    ForEach(tool.output) { entry in
                        outputRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: tool.output.count) { _, _ in
                if let last = tool.output.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .background(Color.primary.opacity(0.02))
    }

    private func outputRow(_ entry: DBOutputEntry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: entry.direction))
                    .font(.system(size: 9))
                    .foregroundStyle(color(for: entry.direction))
                Text(entry.time.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(entry.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(color(for: entry.direction))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func icon(for direction: DBOutputEntry.Direction) -> String {
        switch direction {
        case .input: return "chevron.right"
        case .output: return "text.justify.left"
        case .error: return "exclamationmark.triangle"
        case .info: return "info.circle"
        }
    }

    private func color(for direction: DBOutputEntry.Direction) -> Color {
        switch direction {
        case .input: return .secondary
        case .output: return .primary
        case .error: return .red
        case .info: return .secondary
        }
    }

    // MARK: - 输入区

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text(">")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            TextField("输入 SQL 或 Redis 命令（⌘↩ 执行）", text: $tool.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1...5)
                .onSubmit { tool.execute() }
                .disabled(tool.isRunning || tool.selectedConnection == nil)
            Button {
                tool.execute()
            } label: {
                if tool.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.plain)
            .padding(6)
            .background(
                Circle().fill(tool.selectedConnection != nil && !tool.isRunning
                              ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
            )
            .disabled(tool.isRunning || tool.selectedConnection == nil)
            .help("执行（⌘↩）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
