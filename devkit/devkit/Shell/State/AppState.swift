//
//  AppState.swift
//  devkit
//
//  App 全局状态：启动阶段、TabManager 装配、会话持久化协调。
//

import Foundation
import SwiftUI

/// App 生命周期阶段。
enum AppPhase: Equatable {
    /// 未选择数据目录：必须展示引导页
    case needsOnboarding
    /// 正在尝试打开数据库（启动恢复期）
    case booting
    /// 就绪：可以进入主界面
    case ready
    /// 启动失败：展示错误重试界面
    case failed(String)
}

/// 全局应用状态。所有 Shell 视图依赖此对象。
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    // MARK: - State

    private(set) var phase: AppPhase = .booting
    let tabManager: TabManager
    let windowID: UUID = UUID()

    /// 关闭 tab 时若有未保存内容需要用户确认；M1 用最小编辑器：一次一个 pending。
    var pendingCloseTabID: UUID?

    /// 需弹出“保存位置”对话框的 tab（首次 ⌘S）；nil 表示不弹。
    var pendingSaveTabID: UUID?
    /// 新建 HTTP 标签后需弹出“新建 / 打开已保存”选择框的 tab。
    var httpChooserTabID: UUID?
    /// 新建 SSH 标签后需弹出“本地 / 新建 SSH / 选择已有”选择框的 tab。
    var sshChooserTabID: UUID?

    /// 设置面板是否展示（侧栏左下角设置按钮 / 菜单「设置…」⌘,）。
    var isSettingsPresented = false

    // MARK: - Init

    /// 仅内部使用；外部通过 `.shared`。default 参数 需 caller 处于 MainActor，因此直接内部创建。
    private init() {
        self.tabManager = TabManager()
    }

    // MARK: - Boot flow

    /// App 启动流程：偏好→沙盒访问→打开 db→恢复 session→`.ready`。
    func bootstrap() async {
        phase = .booting
        // 开发调试：设置 DEVKIT_DATA_DIR 可直接跳过引导页（仅 DEBUG 构建生效）。
        #if DEBUG
        if let envDir = ProcessInfo.processInfo.environment["DEVKIT_DATA_DIR"],
           !envDir.isEmpty {
            let dir = URL(fileURLWithPath: envDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            completeOnboarding(with: dir)
            seedDemoSessionIfRequested()
            openSettingsIfRequested()
            DebugSnapshot.runIfRequested(appState: self)
            await DebugSelfCheck.runIfRequested()
            return
        }
        #endif
        guard let dir = AppPreferences.shared.dataDirectoryURL,
              let dbFile = AppPreferences.shared.databaseFileURL else {
            phase = .needsOnboarding
            return
        }
        AppPreferences.shared.beginAccessing(dir)
        do {
            try DatabaseManager.shared.open(at: dbFile)
            restoreSession()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 引导页完成：保存书签 + 建库 + 恢复空会话。
    func completeOnboarding(with directory: URL) {
        do {
            try AppPreferences.shared.setDataDirectory(directory)
            let dbFile = directory.appendingPathComponent("devkit.sqlite3")
            try DatabaseManager.shared.open(at: dbFile)
            restoreSession()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 重置数据目录设置（用于设置页；不删除实际文件）。
    func resetDataDirectory() {
        DatabaseManager.shared.close()
        AppPreferences.shared.clearDataDirectory()
        phase = .needsOnboarding
    }

    #if DEBUG
    /// 调试专用：当 `DEVKIT_SEED_DEMO=1` 时创建演示标签与分组，便于验证侧栏/标签 UI。
    /// `DEVKIT_SEED_COUNT` 控制标签数量（默认 3），用于测试竖向溢出滚动。
    private func seedDemoSessionIfRequested() {
        guard ProcessInfo.processInfo.environment["DEVKIT_SEED_DEMO"] == "1" else { return }
        // 先清空恢复出的旧会话，保证演示状态确定。
        for tab in tabManager.tabs { tabManager.close(tabID: tab.id) }
        let registry = ToolRegistry.shared
        let ids = ["tool.http", "tool.json", "tool.ssh"]
        let count = max(1, Int(ProcessInfo.processInfo.environment["DEVKIT_SEED_COUNT"] ?? "3") ?? 3)
        var opened: [Tab] = []
        for i in 0..<count {
            guard let d = registry.descriptor(for: ids[i % ids.count]),
                  let tab = tabManager.openTool(descriptor: d) else { continue }
            tabManager.rename(tabID: tab.id, to: "标签 \(i + 1)")
            opened.append(tab)
        }
        // 前两个标签归入一个分组，验证分组行与颜色渲染。
        if opened.count >= 2 {
            tabManager.createGroup(with: [opened[0].id, opened[1].id], name: "项目A", color: .blue)
            tabManager.rename(tabID: opened[0].id, to: "用户接口")
            tabManager.rename(tabID: opened[1].id, to: "配置文档")
        }
        if let first = opened.first { tabManager.select(first.id) }
        saveSession()
    }

    /// 调试专用：`DEVKIT_OPEN_SETTINGS=1` 时启动即打开设置面板，便于迭代其 UI。
    private func openSettingsIfRequested() {
        guard ProcessInfo.processInfo.environment["DEVKIT_OPEN_SETTINGS"] == "1" else { return }
        isSettingsPresented = true
    }
    #endif

    // MARK: - Session

    /// 防抖落盘任务；连续编辑只保留最后一次，避免每敲一键就写库。
    private var sessionSaveTask: Task<Void, Never>?

    func saveSession() {
        // 立即保存时取消挂起的防抖任务，防止其稍后用更旧的状态覆盖。
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        let snapshot = SessionSnapshot(
            version: SessionSnapshot.currentVersion,
            savedAt: .now,
            windows: [tabManager.snapshot(windowID: windowID)]
        )
        try? SessionStore.save(snapshot)
    }

    /// 内容变更后的延迟保存：短防抖窗口内合并多次触发，保证退出/崩溃前最新编辑已落盘。
    func scheduleSessionSave(debounce: TimeInterval = 0.5) {
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            if Task.isCancelled { return }
            self?.saveSession()
        }
    }

    private func restoreSession() {
        guard let snapshot = SessionStore.load(),
              let window = snapshot.windows.first
        else {
            tabManager.isLauncherPresented = true
            return
        }
        tabManager.restore(window)
    }

    // MARK: - Tab 快捷入口

    func openTool(_ descriptor: ToolDescriptor) {
        tabManager.openTool(descriptor: descriptor)
        saveSession()
    }

    func closeTab(_ id: UUID) {
        tabManager.close(tabID: id)
        saveSession()
    }

    // MARK: - HTTP 集合保存 / 重命名协调

    /// 获取指定 tab 的 HTTP 工具实例（非 HTTP 返回 nil）。
    func httpTool(forTab id: UUID) -> HTTPTool? {
        tabManager.tabs.first { $0.id == id }?.toolInstance as? HTTPTool
    }

    /// 获取指定 tab 的 SSH 工具实例（非 SSH 返回 nil）。
    func sshTool(forTab id: UUID) -> SSHTool? {
        tabManager.tabs.first { $0.id == id }?.toolInstance as? SSHTool
    }

    /// 反查某工具实例所属 tab id（用于工具视图内重新唤起本标签的选择弹窗）。
    func tabID(for tool: DevkitTool) -> UUID? {
        tabManager.tabs.first { $0.toolInstance === tool }?.id
    }

    /// 提交一次保存：写入/更新记录 + 把标签标题设为保存名 + 持久化会话。返回是否成功。
    @discardableResult
    func commitHTTPSave(tabID: UUID, name: String, folderID: UUID?) -> Bool {
        guard let tool = httpTool(forTab: tabID) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            _ = try tool.persist(name: trimmed, folderID: folderID)
            tabManager.rename(tabID: tabID, to: trimmed)
            saveSession()
            return true
        } catch {
            return false
        }
    }

    /// 统一重命名入口：改标签标题；若为已保存 HTTP，同步回写记录名。
    func renameHTTP(tabID: UUID, newTitle: String) {
        tabManager.rename(tabID: tabID, to: newTitle)
        if let tool = httpTool(forTab: tabID), tool.isSaved, !newTitle.isEmpty {
            tool.updateSavedName(newTitle)
        }
        saveSession()
    }

    /// 删除一条已保存请求：连带清掉它对应的历史记录，并同步已打开标签的绑定。
    ///
    /// 放在这里而不是设置面板内部：与 `commitHTTPSave` / `renameHTTP` 同属
    /// 「跨标签的 HTTP 状态协调」，集中一处既便于复用，也让 `DebugSelfCheck` 能直接跑真实实现。
    func deleteSavedHTTPRequest(_ id: UUID) {
        try? HTTPCollectionStore.deleteRequest(id: id)
        // 以「记录是否真的没了」为准再解绑：删除可能因库未打开等原因没生效，
        // 那种情况下解绑会让记录还在、标签却丢了绑定（`deleteRequest` 在库未打开时是静默 return）。
        guard HTTPCollectionStore.load(id: id) == nil else { return }
        // 连带删除该记录“自身发出”的历史（按 saved_request_id 外键精确匹配，不误伤同 URL 其它来源）。
        let didTouchHistory = HTTPHistoryStore.deleteForSavedRequest(id) > 0
        // 已打开标签若正绑定这条记录则解绑：内容保留、重新出现未保存标记 `*`，⌘S 改走“另存为”。
        var didDetach = false
        for tab in tabManager.tabs {
            if let tool = tab.toolInstance as? HTTPTool, tool.savedRequestID == id {
                tool.detachSavedRecord()
                didDetach = true
            }
        }
        // 历史变了，让已打开的 HTTP 标签重读列表，避免面板与标签内历史不一致。
        if didTouchHistory { reloadOpenHTTPTabsHistory() }
        // 解绑改变了可持久化状态（savedRequestID / lastSavedRequest），必须落盘一次；
        // 否则强杀或开发重编译后，会话快照里还留着指向已删记录的 ID。
        if didDetach { scheduleSessionSave() }
    }

    /// 移动一条已保存请求到目标文件夹（`folderID == nil` = 根），并同步已打开标签的文件夹绑定。
    func moveSavedHTTPRequest(id: UUID, toFolder folderID: UUID?) {
        HTTPCollectionStore.moveRequest(id: id, to: folderID)
        // 正绑定这条记录的标签：内容不变，仅把「保存位置」跟着改，避免标签仍指向旧文件夹。
        var didTouch = false
        for tab in tabManager.tabs {
            if let tool = tab.toolInstance as? HTTPTool, tool.savedRequestID == id {
                tool.savedFolderID = folderID
                didTouch = true
            }
        }
        if didTouch { scheduleSessionSave() }
    }

    /// 删除一个 HTTP 文件夹（级联删子孙文件夹及其中的请求），连带清掉这些请求的历史，并解绑相应已打开标签。
    func deleteHTTPFolder(id: UUID) {
        // 先在删除前算出将被级联移除的文件夹集：用于筛出受影响请求。
        let folders = HTTPCollectionStore.allFolders()
        var folderSet: Set<UUID> = [id]
        var frontier: [UUID] = [id]
        while let current = frontier.popLast() {
            for f in folders where f.parentID == current && !folderSet.contains(f.id) {
                folderSet.insert(f.id)
                frontier.append(f.id)
            }
        }
        let affected = HTTPCollectionStore.allRequests()
            .filter { fid in fid.folderID.map { folderSet.contains($0) } ?? false }
        let affectedRequestIDs = Set(affected.map(\.id))

        try? HTTPCollectionStore.deleteFolder(id: id)

        // 连带删除被级联移除记录“自身发出”的历史（按 saved_request_id）。
        var didTouchHistory = false
        for rid in affectedRequestIDs {
            if HTTPHistoryStore.deleteForSavedRequest(rid) > 0 { didTouchHistory = true }
        }

        var didDetach = false
        for tab in tabManager.tabs {
            if let tool = tab.toolInstance as? HTTPTool,
               let bound = tool.savedRequestID, affectedRequestIDs.contains(bound) {
                tool.detachSavedRecord()
                didDetach = true
            }
        }
        if didTouchHistory { reloadOpenHTTPTabsHistory() }
        if didDetach { scheduleSessionSave() }
    }

    /// 让所有已打开的 HTTP 标签重读历史列表（历史被外部增删后同步面板与标签）。
    private func reloadOpenHTTPTabsHistory() {
        for tab in tabManager.tabs {
            (tab.toolInstance as? HTTPTool)?.loadHistory()
        }
    }
}
