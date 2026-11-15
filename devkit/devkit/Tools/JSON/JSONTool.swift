//
//  JSONTool.swift
//  devkit
//
//  JSON Studio（M3）：文本编辑器 + 只读树形双视图，格式化 / 压缩 / 校验 / 键排序。
//  无长期存储（不入库、无 ⌘S）；但标签内容随会话快照保存，App 重启后原样还原。
//

import SwiftUI

/// 内容呈现模式。
enum JSONViewMode: String, CaseIterable, Codable {
    case code
    case tree

    var label: String {
        switch self {
        case .code: return L("文本")
        case .tree: return L("树形")
        }
    }
}

@Observable
final class JSONTool: DevkitTool {
    static let descriptor = ToolDescriptor(
        id: "tool.json",
        title: "JSON 工具",
        symbolName: "curlybraces",
        category: .data,
        subtitle: "文本 / 树形双视图编辑、格式化、校验、键排序。",
        allowsMultipleInstances: true,
        supportsWindowDetach: true
    )

    var descriptor: ToolDescriptor { Self.descriptor }

    // MARK: - 状态

    /// 唯一数据源：编辑器里的原始 JSON 文本。
    var text: String = "" {
        didSet { if text != oldValue { reparse() } }
    }

    /// 当前呈现模式（文本 / 树形）。
    var viewMode: JSONViewMode = .code

    /// 格式化缩进风格。
    var indent: JSONIndent = .spaces2

    /// 解析结果：成功时的值模型；随 `text` 变更重算。
    private(set) var parsedValue: JSONValue?

    /// 解析错误；`nil` 表示当前文本合法（或为空）。
    private(set) var parseError: JSONError?

    /// 是否有内容（决定空状态与操作可用性）。
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 当前文本是否解析通过（格式化/压缩/排序的可用性前提）。
    var isValid: Bool { parsedValue != nil }

    /// 字符数（图表素数）。
    var characterCount: Int { text.count }

    /// 行数（空文档记 1）。
    var lineCount: Int { text.components(separatedBy: .newlines).count }

    // MARK: 搜索（瞬时状态，不进会话快照）

    /// 搜索栏是否可见。
    var isSearchVisible = false

    /// 鼠标是否悬停在悬浮搜索栏上；编辑器据此让出 I 型光标控制权
    /// （NSTextView 的光标跟踪区不理会上层浮层，需显式抑制）。
    var isPointerOverFindBar = false

    /// 搜索关键字（大小写不敏感子串匹配）。
    var searchQuery = ""

    /// 当前关键字在文本中的命中总数；由编辑器侧（Coordinator）重算后回写，UI 只读。
    var searchMatchCount = 0

    /// 当前聚焦的命中序号（0 基，编辑器据此选中并滚动定位）。
    var searchMatchIndex = 0

    /// 唤出搜索栏：树形模式下先切回文本视图（搜索只在文本编辑器里做）。
    func openSearch() {
        viewMode = .code
        isSearchVisible = true
    }

    /// 关闭搜索栏并清空搜索状态。
    func closeSearch() {
        isSearchVisible = false
        isPointerOverFindBar = false
        searchQuery = ""
        searchMatchCount = 0
        searchMatchIndex = 0
    }

    /// 跳到下一个命中（到尾回绕）；无命中时无操作。
    func nextSearchMatch() {
        guard searchMatchCount > 0 else { return }
        searchMatchIndex = (searchMatchIndex + 1) % searchMatchCount
    }

    /// 跳到上一个命中（到头回绕）；无命中时无操作。
    func previousSearchMatch() {
        guard searchMatchCount > 0 else { return }
        searchMatchIndex = (searchMatchIndex - 1 + searchMatchCount) % searchMatchCount
    }

    init() {}

    // MARK: - DevkitTool

    /// JSON 无长期存储，标题保持默认工具名（用户可自定义标签标题，由 Shell 持久化）。
    var dynamicTabTitle: String? { nil }

    /// 无保存目标，内容靠会话快照自动留存，关闭标签不弹未保存提醒。
    var hasUnsavedContent: Bool { false }

    @MainActor func makeView() -> AnyView {
        AnyView(JSONToolView(tool: self))
    }

    // MARK: - 行为

    /// 文本变更后重算解析结果（同步，MVP 规模足够）。
    private func reparse() {
        if isEmpty {
            parsedValue = nil
            parseError = nil
            return
        }
        switch JSONParser.parse(text) {
        case .success(let value):
            parsedValue = value
            parseError = nil
        case .failure(let error):
            parsedValue = nil
            parseError = error
        }
    }

    /// 文本非法时无操作；合法时按当前缩进重新美化。
    func format() {
        guard let value = parsedValue else { return }
        text = JSONSerializer.pretty(value, indent: indent)
    }

    /// 压缩：去除所有结构空白。
    func minify() {
        guard let value = parsedValue else { return }
        text = JSONSerializer.minify(value)
    }

    /// 键排序后以当前缩进写回。
    func sortKeys(ascending: Bool, recursive: Bool) {
        guard let value = parsedValue else { return }
        let sorted = value.sortedKeys(ascending: ascending, recursive: recursive)
        text = JSONSerializer.pretty(sorted, indent: indent)
    }

    // MARK: - 会话状态持久化

    /// 随标签快照持久化的内部状态。
    private struct SessionState: Codable {
        var text: String
        var viewMode: JSONViewMode
        var indent: JSONIndent
    }

    /// 空文本且为默认模式时返回 nil（无需占用快照空间）。
    @MainActor func sessionStateData() -> Data? {
        if isEmpty, viewMode == .code, indent == .spaces2 { return nil }
        let state = SessionState(text: text, viewMode: viewMode, indent: indent)
        return try? JSONEncoder().encode(state)
    }

    /// 从快照恢复：回填文本/模式/缩进（`text` 赋值会触发重解析）。
    @MainActor func restoreSessionState(_ data: Data) {
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
        viewMode = state.viewMode
        indent = state.indent
        text = state.text
    }
}
