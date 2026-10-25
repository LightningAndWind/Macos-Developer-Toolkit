//
//  DBTool.swift
//  devkit
//
//  M6：数据库工具（MySQL / Redis）。命令行式控制台：选一条已保存连接，输入 SQL / Redis
//  命令（多行 = 多条），⌘↩ 执行，输出按方向着色滚动展示。执行引擎见 DBExecService
//  （无状态单次执行：连接 → 认证 → 执行 → 断开）。应用内控制台与 AI 接入（MCP）共用引擎。
//

import Foundation
import SwiftUI

/// 一条输出条目。
struct DBOutputEntry: Identifiable {
    enum Direction {
        /// 用户输入（回显）。
        case input
        /// 执行结果。
        case output
        /// 错误。
        case error
        /// 提示信息（连接上下文等）。
        case info
    }

    let id = UUID()
    let time = Date()
    let direction: Direction
    let text: String
}

/// 数据库工具实例（一个标签一份）。
@Observable
final class DBTool: DevkitTool {
    static let descriptor = ToolDescriptor(
        id: "tool.db",
        title: "数据库",
        symbolName: "cylinder.and.ellipse",
        category: .network,
        subtitle: "连接 MySQL / Redis，命令行式执行 SQL 与命令，也可供 AI 通过本地接口使用。",
        allowsMultipleInstances: true,
        supportsWindowDetach: true
    )

    var descriptor: ToolDescriptor { Self.descriptor }

    // MARK: - 状态

    /// 连接列表快照（打开标签 / 增删改后刷新）。
    private(set) var connections: [DBConnection] = []
    /// 当前选中的连接。
    var selectedConnectionID: UUID?
    /// 输出历史（仅本标签内存，不持久化）。
    private(set) var output: [DBOutputEntry] = []
    /// 输入草稿（随会话快照持久化）。
    var inputText = ""
    /// 是否有执行在途（引擎无状态，但同一标签一次只跑一条，避免输出交错）。
    private(set) var isRunning = false

    /// 在途执行任务（关标签时取消——引擎的 await 会随 NIO future 完成自然结束）。
    private var runningTask: Task<Void, Never>?

    var selectedConnection: DBConnection? {
        connections.first { $0.id == selectedConnectionID }
    }

    init() {
        refreshConnections()
    }

    // MARK: - DevkitTool

    var dynamicTabTitle: String? {
        selectedConnection?.name
    }

    var hasUnsavedContent: Bool {
        !output.isEmpty
    }

    func makeView() -> AnyView {
        AnyView(DBToolView(tool: self))
    }

    /// 会话快照：只存选中连接与输入草稿（输出不持久化，重启后从空白开始）。
    private struct SessionState: Codable {
        var selectedConnectionID: UUID?
        var inputText: String
    }

    func sessionStateData() -> Data? {
        guard let state = try? JSONEncoder().encode(
            SessionState(selectedConnectionID: selectedConnectionID, inputText: inputText)
        ) else { return nil }
        return state
    }

    func restoreSessionState(_ data: Data) {
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
        refreshConnections()
        // 连接可能已被删除：只在仍存在时回填。
        if let id = state.selectedConnectionID, connections.contains(where: { $0.id == id }) {
            selectedConnectionID = id
        }
        inputText = state.inputText
    }

    /// 关标签：取消在途执行（结果不再回写即可；引擎连接自会关闭）。
    func teardownOnTabClose() {
        runningTask?.cancel()
        runningTask = nil
    }

    // MARK: - 数据

    /// 重读连接列表（新建 / 编辑 / 删除后调用）。
    func refreshConnections() {
        connections = DBConnectionStore.all()
        if let id = selectedConnectionID, !connections.contains(where: { $0.id == id }) {
            selectedConnectionID = nil
        }
        if selectedConnectionID == nil {
            selectedConnectionID = connections.first?.id
        }
    }

    func clearOutput() {
        output.removeAll()
    }

    // MARK: - 执行

    /// 执行当前输入（输入可多行：MySQL 视作一段 SQL；Redis 每行一条命令）。
    func execute() {
        guard !isRunning, let connection = selectedConnection else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        append(.input, text)
        inputText = ""
        isRunning = true

        let kind = connection.kind
        let host = connection.host
        let port = connection.port
        let username = connection.normalizedUsername
        let password = connection.normalizedPassword
        let database = connection.normalizedDatabase

        runningTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.isRunning = false } }
            do {
                let result: DBExecResult
                switch kind {
                case .mysql:
                    // MySQL 用户名必有（编辑器默认 root）。
                    result = try await DBExec.runMySQL(host: host, port: port,
                                                       username: username ?? "root",
                                                       password: password, database: database,
                                                       sql: text, timeout: DBExec.defaultTimeout)
                case .redis:
                    result = try await DBExec.runRedis(host: host, port: port,
                                                       username: username, password: password,
                                                       database: database,
                                                       commandText: text, timeout: DBExec.defaultTimeout)
                }
                if let errorText = result.errorText {
                    self?.append(.error, errorText)
                } else {
                    var output = result.text
                    if result.truncated { output += "\n…（输出过长已截断）" }
                    self?.append(.output, output)
                }
            } catch {
                self?.append(.error, error.localizedDescription)
            }
        }
    }

    private func append(_ direction: DBOutputEntry.Direction, _ text: String) {
        output.append(DBOutputEntry(direction: direction, text: text))
        // 输出上限：控制内存与渲染量。
        if output.count > 500 {
            output.removeFirst(output.count - 500)
        }
    }
}
