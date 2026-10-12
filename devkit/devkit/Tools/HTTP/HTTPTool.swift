//
//  HTTPTool.swift
//  devkit
//
//  HTTP 请求工具（M2 完整实现）。
//  视图模型：持有当前请求、响应、历史；驱动 HTTPToolView 渲染。
//

import SwiftUI

@Observable
final class HTTPTool: DevkitTool {
    static let descriptor = ToolDescriptor(
        id: "tool.http",
        title: "HTTP 请求",
        symbolName: "arrow.up.arrow.down.square",
        category: .network,
        subtitle: "构造并发送 HTTP 请求，查看响应与历史记录。",
        allowsMultipleInstances: true,
        supportsWindowDetach: true
    )

    var descriptor: ToolDescriptor { Self.descriptor }

    // MARK: - 状态

    var request = HTTPRequestModel()
    var response: HTTPResponseModel?
    var history: [HTTPHistoryRecord] = []
    var isLoading = false
    var errorMessage: String?

    /// 最近一次请求是否由用户主动「停止」。
    ///
    /// 单列一个状态而不是复用 `errorMessage`：主动停止不是故障，弹红色警告条只会让人以为出了错。
    /// 视图侧据此渲染中性的「已取消」空状态。
    private(set) var lastRequestCancelled = false

    /// 在途请求句柄 —— 有它才能取消。
    ///
    /// 以前视图里写 `Task { await tool.send() }`，那个 Task 没有任何引用，
    /// 用户点了停止也够不着；超时上限提到 1 小时后，没有取消就只能干等。
    private var inFlightTask: Task<Void, Never>?

    /// 关联的已保存记录 ID；`nil` 表示新建/未保存（与“根目录”区分）。
    var savedRequestID: UUID?
    /// 保存时所属文件夹；`nil` = 根。
    var savedFolderID: UUID?
    /// 最近一次保存/打开时的请求快照；用于判定是否有未保存的修改（`*` 标记与关闭提醒）。
    var lastSavedRequest: HTTPRequestModel?
    /// 历史是否已从库加载过一次；避免每次切回标签都在主线程同步读库+解码，造成卡顿。
    private(set) var hasLoadedHistory = false

    // MARK: - DevkitTool

    /// 标签动态标题 = 请求 URL 的 host。
    var dynamicTabTitle: String? {
        guard let host = URL(string: request.trimmedURLString)?.host, !host.isEmpty else { return nil }
        return host
    }

    var hasUnsavedContent: Bool {
        // 非“有内容”，而是“有未保存的改动”：空请求不算；与最近一次保存的快照不同才算脏。
        guard !request.isEmpty else { return false }
        return request != lastSavedRequest
    }

    var supportsSave: Bool { true }
    var isSaved: Bool { savedRequestID != nil }

    init() {}

    @MainActor func makeView() -> AnyView {
        AnyView(HTTPToolView(tool: self))
    }

    // MARK: - 行为

    /// 发送当前请求，写入响应并记录历史。
    ///
    /// 同步返回、自己创建并持有 Task（而不是让视图 `Task { await send() }`）——
    /// 否则「停止」拿不到句柄。`isLoading` 在这里就置位，避免「已点发送但按钮还没锁上」的空窗。
    func send() {
        guard !request.isEmpty, inFlightTask == nil else { return }
        isLoading = true
        errorMessage = nil
        lastRequestCancelled = false

        // 捕获本次请求的快照：`performSend` 里要用的超时、以及历史落库都以发出那一刻为准，
        // 免得请求在途时用户改了编辑器内容，历史里存下的却成了改后的版本。
        let sentRequest = request
        inFlightTask = Task { [weak self] in
            await self?.performSend(sentRequest)
            self?.isLoading = false
            self?.inFlightTask = nil
        }
    }

    /// 中断在途请求。取消会一路传到 `URLSession.AsyncBytes`，`performSend` 侧收到 `.cancelled`。
    func cancelSend() {
        inFlightTask?.cancel()
    }

    private func performSend(_ sentRequest: HTTPRequestModel) async {
        do {
            let result = try await HTTPClient(timeout: sentRequest.effectiveTimeout).send(sentRequest)
            response = result
            recordHistory(for: result, request: sentRequest)
        } catch HTTPClientError.cancelled {
            response = nil
            errorMessage = nil
            lastRequestCancelled = true
            // 仍然落一条无响应的历史：请求确实发出去了，回看时「有一条被取消的记录」
            // 比「什么都没有」更好解释，也与失败路径的处理保持一致。
            recordHistory(for: nil, request: sentRequest)
        } catch {
            response = nil
            errorMessage = error.localizedDescription
            recordHistory(for: nil, request: sentRequest)
        }
    }

    /// 载入最近历史（视图 onAppear 调用）。
    func loadHistory() {
        history = HTTPHistoryStore.recent()
        hasLoadedHistory = true
    }

    /// 视图出现时调用：仅在首次真正查库。之后依赖发请求后的 recordHistory 刷新，
    /// 避免每次切换到本标签都重建视图时重复同步读库。
    func ensureHistoryLoaded() {
        guard !hasLoadedHistory else { return }
        loadHistory()
    }

    /// 按关键字刷新历史列表；空查询回到最近。
    func refreshHistory(query: String) {
        history = HTTPHistoryStore.search(query)
    }

    /// 重发：把历史记录的请求灌回当前编辑器。
    func applyHistory(_ record: HTTPHistoryRecord) {
        request = record.request
        response = nil
        errorMessage = nil
        lastRequestCancelled = false
    }

    func deleteHistory(_ record: HTTPHistoryRecord) {
        try? HTTPHistoryStore.delete(id: record.id)
        history.removeAll { $0.id == record.id }
    }

    func clearHistory() {
        try? HTTPHistoryStore.clearAll()
        history = []
    }

    /// 当前请求的 cURL 命令（供"复制为 cURL"）。
    func curlCommand() -> String {
        CurlExporter.curlCommand(from: request)
    }

    /// 清空请求编辑器。
    func resetRequest() {
        request = HTTPRequestModel()
        response = nil
        errorMessage = nil
        lastRequestCancelled = false
    }

    // MARK: - 集合保存（M5）

    /// 将当前请求写入记录：已有 savedRequestID 则更新，否则新建。返回记录 id。
    @discardableResult
    func persist(name: String, folderID: UUID?) throws -> UUID {
        let id = savedRequestID ?? UUID()
        let createdAt = savedRequestID.flatMap { HTTPCollectionStore.load(id: $0)?.createdAt } ?? .now
        let record = HTTPSavedRequest(id: id,
                                      folderID: folderID,
                                      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                      request: request,
                                      createdAt: createdAt,
                                      updatedAt: .now)
        try HTTPCollectionStore.save(record)
        savedRequestID = id
        savedFolderID = folderID
        lastSavedRequest = request
        return id
    }

    /// 已保存时的原地更新（⌘S）；未保存时无操作，由 Shell 走另存弹框。
    @MainActor func saveViaShell() throws {
        guard let id = savedRequestID else { return }
        guard let existing = HTTPCollectionStore.load(id: id) else {
            // 绑定的记录已不存在（典型场景：在设置面板里把它删了，而标签还指着它）。
            // 必须解绑再返回，否则这里静默什么都不做 —— 用户按 ⌘S 毫无反馈，
            // 且下次 ⌘S 仍会走进同一条死路。解绑后 `isSaved` 为 false，Shell 会改走「另存为」弹框。
            detachSavedRecord()
            return
        }
        try persist(name: existing.name, folderID: existing.folderID)
    }

    /// 仅同步已保存记录的名称（标签栏重命名回写）；不触碰请求内容。
    func updateSavedName(_ name: String) {
        guard let id = savedRequestID else { return }
        HTTPCollectionStore.renameRequest(id: id, name: name)
    }

    /// 记录被外部（设置面板）删除后解绑：编辑器内容保留，但不再指向已不存在的记录，
    /// 于是 `isSaved` 转为 false、并重新出现未保存标记 `*`，⌘S 会走“另存为”。
    func detachSavedRecord() {
        savedRequestID = nil
        savedFolderID = nil
        lastSavedRequest = nil
    }

    /// 从已保存记录载入到当前编辑器，并绑定为“已保存”状态。
    func applySaved(_ record: HTTPSavedRequest) {
        request = record.request
        response = nil
        errorMessage = nil
        lastRequestCancelled = false
        savedRequestID = record.id
        savedFolderID = record.folderID
        lastSavedRequest = record.request
    }

    // MARK: - 会话状态持久化

    /// 随标签快照持久化的工具内部状态（仅请求与保存绑定；不存响应/历史，重发即可再取）。
    private struct SessionState: Codable {
        var request: HTTPRequestModel
        var savedRequestID: UUID?
        var savedFolderID: UUID?
        var lastSavedRequest: HTTPRequestModel?
    }

    /// 导出当前状态给会话快照；空请求且未保存时返回 nil（无需占用）。
    @MainActor func sessionStateData() -> Data? {
        if request.isEmpty, savedRequestID == nil { return nil }
        let state = SessionState(request: request,
                                 savedRequestID: savedRequestID,
                                 savedFolderID: savedFolderID,
                                 lastSavedRequest: lastSavedRequest)
        return try? JSONEncoder().encode(state)
    }

    /// 从快照恢复：回填请求与保存绑定，保留脏判定基准（`*` 与 ⌘S 更新目标不变）。
    @MainActor func restoreSessionState(_ data: Data) {
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
        request = state.request
        savedRequestID = state.savedRequestID
        savedFolderID = state.savedFolderID
        lastSavedRequest = state.lastSavedRequest
    }

    // MARK: - Private

    /// 记录一条历史。
    ///
    /// `request` 显式传入发出那一刻的快照，而不是读 `self.request`：
    /// 请求在途时用户完全可以继续改编辑器内容（改 URL、换 body），
    /// 那时历史里该存的是「实际发出去的那份」，否则回看历史会看到一份从未发送过的请求。
    private func recordHistory(for response: HTTPResponseModel?, request sentRequest: HTTPRequestModel) {
        // 带上当前绑定关系：已保存标签发出的历史才能被“删除该记录时连带清理”精确命中；未保存时传 nil。
        try? HTTPHistoryStore.insert(request: sentRequest, response: response, savedRequestID: savedRequestID)
        history = HTTPHistoryStore.recent()
    }
}
