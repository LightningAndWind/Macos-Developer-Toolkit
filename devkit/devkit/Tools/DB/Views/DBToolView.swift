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
    /// 提示符输入行聚焦（点击输出区任意处回到输入）。
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            outputArea
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

    // MARK: - 输出区（终端流：历史输出 + 末尾提示符输入行，始终从顶部开始）

    private var outputArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(tool.output) { entry in
                        outputRow(entry)
                            .id(entry.id)
                    }
                    inputLine
                        .id("input-line")
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { isInputFocused = true }
            }
            .onChange(of: tool.output.count) { _, _ in
                proxy.scrollTo("input-line", anchor: .bottom)
            }
        }
        .background(Color.primary.opacity(0.02))
    }

    private func outputRow(_ entry: DBOutputEntry) -> some View {
        // 终端流式风格：不带图标与时间戳，输入回显自带 mysql> / redis> 提示符。
        Text(entry.text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(color(for: entry.direction))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 流末尾的提示符输入行：MySQL 以 `;` 结尾回车执行、否则续行（`->`）；Redis 回车即执行。
    private var inputLine: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(promptText)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(tool.selectedConnection == nil ? Color.secondary : Color.primary)
            TextField("", text: $tool.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .focused($isInputFocused)
                .disabled(tool.isRunning || tool.selectedConnection == nil)
                .onSubmit { tool.submitLine() }
                .placeholder(when: tool.inputText.isEmpty) {
                    Text(tool.isRunning
                         ? "执行中…"
                         : (tool.selectedConnection == nil
                            ? "先在上方选择连接"
                            : "回车执行；SQL 未以 ; 结尾则换行继续输入"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .allowsHitTesting(false)
                }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// 提示符：MySQL 续行态显示 `->`（与 mysql CLI 一致），Redis 恒为 `redis>`。
    private var promptText: String {
        guard let kind = tool.selectedConnection?.kind else { return "mysql> " }
        if kind == .redis { return "redis> " }
        return tool.pendingLines.isEmpty ? "mysql> " : "    -> "
    }

    private func color(for direction: DBOutputEntry.Direction) -> Color {
        switch direction {
        case .input: return .primary
        case .output: return .primary
        case .error: return .red
        case .info: return .secondary
        }
    }
}

extension View {
    /// TextField(.plain) 的轻量 placeholder（覆盖在输入区上方，不拦截点击）。
    @ViewBuilder
    func placeholder(when condition: Bool, @ViewBuilder content: () -> some View) -> some View {
        ZStack(alignment: .leading) {
            if condition { content() }
            self
        }
    }
}
