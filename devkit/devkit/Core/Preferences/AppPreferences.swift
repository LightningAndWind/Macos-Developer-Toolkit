//
//  AppPreferences.swift
//  devkit
//
//  应用偏好：数据存储目录（默认落在 ~/Library/Application Support/devkit/data，
//  可在设置中迁移到别的目录）+ 侧栏宽度等 UI 偏好键。
//

import Foundation

/// 应用偏好设置。存 UserDefaults；bookmark 用于沙盒下重新访问用户选择的目录。
@MainActor
final class AppPreferences {
    static let shared = AppPreferences()

    /// 侧栏展开态宽度档位键（`Theme.SidebarWidthMode.rawValue`）。
    /// 视图侧用 `@AppStorage` 直接绑定枚举，两个视图（主界面 / 标签栏按钮）自动同步。
    static let sidebarWidthModeKey = "devkit.sidebar.widthMode"

    /// 侧栏超窄模式偏好键（标准档一半宽度，标签行样式不变）。
    static let sidebarCollapsedKey = "devkit.sidebar.collapsed"

    /// 外观模式偏好键（跟随系统 / 浅色 / 深色）。视图侧用 `@AppStorage` 绑定，见 `AppAppearanceMode`。
    static let appearanceModeKey = "devkit.appearance.mode"

    /// 界面语言偏好键（跟随系统 / 简体中文 / English）。视图侧用 `@AppStorage` 绑定，见 `AppLanguageMode`。
    static let languageOverrideKey = "devkit.language.override"

    /// 防止锁屏开关偏好键。视图侧用 `@AppStorage` 绑定（见 `SidebarFooterBar`），生效走 `SleepKeeper`。
    static let preventSleepKey = "devkit.sleep.prevent"

    private enum Keys {
        static let dataBookmark = "devkit.dataDir.bookmark"
        static let dataPath     = "devkit.dataDir.path"
    }

    /// 未另选数据目录时的默认位置：`~/Library/Application Support/devkit/data`。
    /// 首次启动直接使用默认目录（不再强制选择）；之后可在设置中迁移到新目录（如同步盘）。
    static let defaultDataDirectoryURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("devkit", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
    }()

    private let defaults: UserDefaults
    /// 当前正在访问的安全作用域 URL（需要成对调用 stop）。
    private var accessingURL: URL?
    /// 临时数据目录（仅本进程生效，不落盘）：DEBUG + DEVKIT_DATA_DIR 自检 / 冒烟专用。
    /// 为什么不走 setDataDirectory：那会把临时路径经 cfprefsd 持久化（缓存 + 磁盘），
    /// 之后真实启动读到已删除的临时目录 → 「Failed to open database」启动失败（实测踩过）。
    private var ephemeralDataDirectoryURL: URL?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 是否仍在使用默认数据目录（从未迁移过）。
    var isUsingDefaultDataDirectory: Bool {
        dataDirectoryURL == nil
    }

    /// 数据目录（用户显式选择过的）。临时目录（自检模式）优先；其次以记录的绝对路径为准
    /// （关闭沙盒后可直接访问任意路径）；若路径缺失则回退解析历史书签（旧沙盒构建存的
    /// security-scope 书签）。**不含默认目录回退**——那是 `resolvedDataDirectoryURL()` 的职责，
    /// 二者分开才能区分「默认 / 已迁移」展示与旧书签解析。
    var dataDirectoryURL: URL? {
        if let ephemeralDataDirectoryURL { return ephemeralDataDirectoryURL }
        if let path = defaults.string(forKey: Keys.dataPath), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard let data = defaults.data(forKey: Keys.dataBookmark) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data,
                        options: [.withSecurityScope],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }

    /// 实际生效的数据目录：临时 / 自选目录，否则回落默认目录（不存在则创建）。
    func resolvedDataDirectoryURL() throws -> URL {
        if let url = dataDirectoryURL { return url }
        try FileManager.default.createDirectory(at: Self.defaultDataDirectoryURL,
                                                withIntermediateDirectories: true)
        return Self.defaultDataDirectoryURL
    }

    /// 数据库文件完整路径（`<dir>/devkit.sqlite3`）。
    var databaseFileURL: URL? {
        (try? resolvedDataDirectoryURL())?.appendingPathComponent("devkit.sqlite3")
    }

    /// 选择并记录数据目录。校验目录可写；关闭沙盒后无需 security-scope，直接记录路径。
    func setDataDirectory(_ url: URL) throws {
        try validateDirectoryWritable(url)
        defaults.set(url.path, forKey: Keys.dataPath)
        saveBookmark(for: url)
        // 兼容旧逻辑：尝试激活一次（非沙盒下为无害的空操作）。
        beginAccessing(url)
    }

    /// 设置**仅本进程生效**的临时数据目录（不写 UserDefaults、不存书签）。
    /// 供 DEBUG + DEVKIT_DATA_DIR 的自检 / 冒烟流程使用，绝不污染真实偏好。
    func setEphemeralDataDirectory(_ url: URL) {
        ephemeralDataDirectoryURL = url
    }

    /// 清除数据目录设置（用于设置页更换目录或重置）。
    func clearDataDirectory() {
        stopAccessing()
        defaults.removeObject(forKey: Keys.dataBookmark)
        defaults.removeObject(forKey: Keys.dataPath)
    }

    /// 开始访问沙盒外的用户选择目录；成对调用 `stopAccessing()`。
    @discardableResult
    func beginAccessing(_ url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else { return false }
        accessingURL = url
        return true
    }

    func stopAccessing() {
        accessingURL?.stopAccessingSecurityScopedResource()
        accessingURL = nil
    }

    // MARK: - Private

    /// 存一份普通书签作为路径缺失时的回退；非沙盒下用普通选项即可，且绝不抛出中断引导。
    private func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(options: [],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        defaults.set(data, forKey: Keys.dataBookmark)
    }

    private func validateDirectoryWritable(_ url: URL) throws {
        let probe = url.appendingPathComponent(".devkit-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .atomic)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            throw PreferenceError.directoryNotWritable(url.path)
        }
    }

    enum PreferenceError: LocalizedError {
        case directoryNotWritable(String)
        var errorDescription: String? {
            switch self {
            case .directoryNotWritable(let p): return String(format: L("目录不可写：%@"), String(p))
            }
        }
    }
}
