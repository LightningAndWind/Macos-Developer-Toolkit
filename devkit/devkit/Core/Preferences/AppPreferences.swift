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

    /// 数据目录（返回前会尝试恢复 security-scope 访问权）。
    var dataDirectoryURL: URL? {
        guard let data = defaults.data(forKey: Keys.dataBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale {
            // 尝试刷新一次书签；失败也返回旧 URL 让用户在引导页重新选。
            try? saveBookmark(for: url)
        }
        return url
    }

    /// 数据库文件完整路径（`<dir>/devkit.sqlite3`）。
    var databaseFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("devkit.sqlite3")
    }

    /// 保存并激活目录访问权。校验目录可写。
    func setDataDirectory(_ url: URL) throws {
        try validateDirectoryWritable(url)
        try saveBookmark(for: url)
        defaults.set(url.path, forKey: Keys.dataPath)
        // 立即激活一次，保证随后 open db 能读写
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

    private func saveBookmark(for url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
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
