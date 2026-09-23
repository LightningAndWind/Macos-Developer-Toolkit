//
//  AppPreferences.swift
//  devkit
//
//  应用偏好：数据存储目录（沙盒 security-scoped bookmark）+ 首次启动标记 + 侧栏宽度等 UI 偏好键。
//

import Foundation

/// 应用偏好设置。存 UserDefaults；bookmark 用于沙盒下重新访问用户选择的目录。
@MainActor
final class AppPreferences {
    static let shared = AppPreferences()

    /// 侧栏宽度偏好键。视图侧用 `@AppStorage` 直接绑定，保证拖拽时 SwiftUI 实时刷新。
    static let sidebarWidthKey = "devkit.sidebar.width"

    /// 外观模式偏好键（跟随系统 / 浅色 / 深色）。视图侧用 `@AppStorage` 绑定，见 `AppAppearanceMode`。
    static let appearanceModeKey = "devkit.appearance.mode"

    private enum Keys {
        static let dataBookmark = "devkit.dataDir.bookmark"
        static let dataPath     = "devkit.dataDir.path"
    }

    private let defaults: UserDefaults
    /// 当前正在访问的安全作用域 URL（需要成对调用 stop）。
    private var accessingURL: URL?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 是否已完成首次启动引导。
    var hasCompletedDataDirSetup: Bool {
        dataDirectoryURL != nil
    }

    /// 数据目录。关闭沙盒后以记录的绝对路径为准（可直接访问任意路径）；
    /// 若路径缺失则回退解析历史书签（旧沙盒构建存的是 security-scope 书签）。
    var dataDirectoryURL: URL? {
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

    /// 数据库文件完整路径（`<dir>/devkit.sqlite3`）。
    var databaseFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("devkit.sqlite3")
    }

    /// 选择并记录数据目录。校验目录可写；关闭沙盒后无需 security-scope，直接记录路径。
    func setDataDirectory(_ url: URL) throws {
        try validateDirectoryWritable(url)
        defaults.set(url.path, forKey: Keys.dataPath)
        saveBookmark(for: url)
        // 兼容旧逻辑：尝试激活一次（非沙盒下为无害的空操作）。
        beginAccessing(url)
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
            case .directoryNotWritable(let p): return "目录不可写：\(p)"
            }
        }
    }
}
