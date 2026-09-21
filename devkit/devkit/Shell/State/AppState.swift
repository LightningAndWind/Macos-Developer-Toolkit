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
    #endif

    // MARK: - Session

    func saveSession() {
        let snapshot = SessionSnapshot(
            version: SessionSnapshot.currentVersion,
            savedAt: .now,
            windows: [tabManager.snapshot(windowID: windowID)]
        )
        try? SessionStore.save(snapshot)
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
}
