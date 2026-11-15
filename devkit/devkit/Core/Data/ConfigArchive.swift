//
//  ConfigArchive.swift
//  devkit
//
//  配置记录的导出 / 导入（跨设备或换目录迁移整套使用配置）：
//   - 导出：SQLite 一致性快照（VACUUM INTO，不碰 WAL/SHM 旁文件）+ ssh_keys/ + git_keys/
//     + manifest.json → 临时目录 → /usr/bin/ditto 压成 zip；
//   - 导入：ditto 解压 → 校验 manifest / SQLite 文件头 → 逐项替换当前数据目录内容
//     （旧文件先挪进备份目录，失败可回滚），随后由调用方 relaunch 重启生效；
//   - 迁移：把当前数据快照复制进新目录（源目录文件不动），配合 AppPreferences 切换。
//
//  按既有设计，凭据（密码 / 私钥）随数据明文保存，导出压缩包同样包含凭据——
//  调用方（设置面板）在确认框中明确提示用户妥善保管。
//

import Foundation

/// 配置压缩包服务（nonisolated：纯文件操作；数据目录由调用方在主 actor 解析后传入）.
nonisolated enum ConfigArchive {

    /// 压缩包内的内容根目录名（解压后按它定位内容）。
    static let contentDirectoryName = "devkit-config"
    /// 清单文件名。
    static let manifestFileName = "manifest.json"
    /// 数据库文件名（数据目录内与压缩包内一致）。
    static let databaseFileName = "devkit.sqlite3"
    /// 随库迁移的密钥目录。
    static let keyDirectoryNames = ["ssh_keys", "git_keys"]

    /// 压缩包格式版本（导入侧据此拒绝无法识别的格式）。
    static let formatVersion = "devkit.config.v1"

    /// 压缩包清单。
    struct Manifest: Codable {
        let format: String
        let appVersion: String
        let createdAt: Date
    }

    enum ArchiveError: LocalizedError {
        /// 压缩包不是 devkit 导出的配置包。
        case notADevkitArchive
        /// 压缩包格式版本不被当前版本支持。
        case unsupportedFormat(String)
        /// 压缩包内容缺失 / 损坏。
        case corrupted(String)
        /// ditto 执行失败（参数详情见错误描述）。
        case dittoFailed(String)
        /// 目标路径已被占用（导出文件已存在等）。
        case destinationExists(String)

        var errorDescription: String? {
            switch self {
            case .notADevkitArchive:
                return "这不是 devkit 导出的配置压缩包（缺少清单或内容目录）。"
            case .unsupportedFormat(let v):
                return String(format: L("配置压缩包格式（%@）不被当前版本支持。"), String(v))
            case .corrupted(let reason):
                return String(format: L("配置压缩包内容异常：%@"), String(reason))
            case .dittoFailed(let detail):
                return String(format: L("压缩 / 解压失败：%@"), String(detail))
            case .destinationExists(let path):
                return String(format: L("目标位置已存在：%@"), String(path))
            }
        }
    }

    // MARK: - 导出

    /// 把当前数据目录的配置导出成 zip（写到 `destination`，须不存在）。
    /// 数据库经一致性快照导出，正在进行的写操作不会产生半截文件。
    static func export(to destination: URL, dataDirectory: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ArchiveError.destinationExists(destination.path)
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("devkit-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let content = staging.appendingPathComponent(contentDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)

        // manifest：格式版本 + 应用版本 + 导出时间（导入确认框展示这些信息）。
        let manifest = Manifest(format: formatVersion,
                                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                                createdAt: .now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest)
            .write(to: content.appendingPathComponent(manifestFileName))

        // 数据库一致性快照。
        try DatabaseManager.shared.snapshot(to: content.appendingPathComponent(databaseFileName))

        // 密钥目录（可能不存在：纯密码用户没有 ssh_keys / git_keys）。
        try copyKeyDirectories(from: dataDirectory, to: content)

        // ditto 压缩：--keepParent 保留内容根目录名，导入侧按名定位。
        try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", content.path, destination.path])
    }

    // MARK: - 校验

    /// 解压并校验压缩包，返回清单。不改动任何数据（导入确认框先调它展示信息）。
    static func inspect(zip url: URL) throws -> Manifest {
        let extracted = try extractToTemporaryDirectory(zip: url)
        defer { try? FileManager.default.removeItem(at: extracted.root) }
        return try validate(contents: extracted.content)
    }

    // MARK: - 导入（替换当前数据目录内容）

    /// 把压缩包内容替换进数据目录。**调用前必须已停掉 AI 服务并关闭数据库**；
    /// 替换成功后由调用方 relaunch（内存中的记录缓存 / 已开标签引用全部失效，重启最稳妥）。
    /// 旧文件先挪进备份目录，任一步失败即整体回滚；全部成功后删除备份。
    static func restore(zip url: URL, into dataDirectory: URL) throws {
        let extracted = try extractToTemporaryDirectory(zip: url)
        defer { try? FileManager.default.removeItem(at: extracted.root) }
        _ = try validate(contents: extracted.content)

        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let backup = dataDirectory.appendingPathComponent(".import-backup-\(UUID().uuidString)",
                                                          isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)

        // 1) 旧内容挪进备份（数据库含 WAL/SHM 旁文件；密钥目录整体挪走）。
        var movedOld: [(source: URL, destination: URL)] = []
        do {
            for name in [databaseFileName, databaseFileName + "-wal", databaseFileName + "-shm"] {
                try moveIfExists(dataDirectory.appendingPathComponent(name),
                                 into: backup.appendingPathComponent(name), record: &movedOld)
            }
            for name in keyDirectoryNames {
                try moveIfExists(dataDirectory.appendingPathComponent(name, isDirectory: true),
                                 into: backup.appendingPathComponent(name), record: &movedOld)
            }

            // 2) 新内容就位。
            try FileManager.default.copyItem(at: extracted.content.appendingPathComponent(databaseFileName),
                                             to: dataDirectory.appendingPathComponent(databaseFileName))
            for name in keyDirectoryNames {
                let src = extracted.content.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: src.path) {
                    try FileManager.default.copyItem(at: src,
                                                     to: dataDirectory.appendingPathComponent(name, isDirectory: true))
                }
            }
            try? FileManager.default.removeItem(at: backup)
        } catch {
            // 回滚：新写的内容清掉，旧内容从备份挪回原位（尽力而为，仍失败则把原始错误带出）。
            try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent(databaseFileName))
            for name in keyDirectoryNames {
                try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent(name, isDirectory: true))
            }
            for item in movedOld.reversed() {
                try? FileManager.default.moveItem(at: item.destination, to: item.source)
            }
            try? FileManager.default.removeItem(at: backup)
            throw error
        }
    }

    // MARK: - 迁移（换数据目录）

    /// 把当前数据目录的配置复制到新目录（快照库 + 密钥目录；源目录不动）。
    /// 成功后由调用方 `AppPreferences.setDataDirectory(new)` 指向新目录并 relaunch。
    static func migrate(from source: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.appendingPathComponent(databaseFileName).path) else {
            throw ArchiveError.destinationExists(destination.appendingPathComponent(databaseFileName).path)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try DatabaseManager.shared.snapshot(to: destination.appendingPathComponent(databaseFileName))
        try copyKeyDirectories(from: source, to: destination)
    }

    // MARK: - Private

    private struct Extracted {
        let root: URL
        let content: URL
    }

    /// 解压到唯一临时目录，返回根目录与内容目录（`devkit-config/`）。
    private static func extractToTemporaryDirectory(zip url: URL) throws -> Extracted {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devkit-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try runDitto(["-x", "-k", url.path, root.path])
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        return Extracted(root: root,
                         content: root.appendingPathComponent(contentDirectoryName, isDirectory: true))
    }

    /// 校验内容目录：manifest 可解析、格式版本匹配、SQLite 文件头正确。
    private static func validate(contents content: URL) throws -> Manifest {
        let manifestURL = content.appendingPathComponent(manifestFileName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw ArchiveError.notADevkitArchive
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: data) else {
            throw ArchiveError.notADevkitArchive
        }
        guard manifest.format == formatVersion else {
            throw ArchiveError.unsupportedFormat(manifest.format)
        }
        let dbURL = content.appendingPathComponent(databaseFileName)
        guard let header = try? Data(contentsOf: dbURL, options: .mappedIfSafe).prefix(16),
              header == Data("SQLite format 3\u{0}".utf8) else {
            throw ArchiveError.corrupted(L("压缩包内的数据库文件缺失或不是有效的 SQLite 文件"))
        }
        return manifest
    }

    /// 逐个复制存在的密钥目录。
    private static func copyKeyDirectories(from source: URL, to destination: URL) throws {
        for name in keyDirectoryNames {
            let src = source.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try FileManager.default.copyItem(at: src, to: destination.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// 存在则挪走（moveItem 同盘为原子改名），并记入 `record` 供回滚。
    private static func moveIfExists(_ source: URL, into destination: URL,
                                     record: inout [(source: URL, destination: URL)]) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.moveItem(at: source, to: destination)
        record.append((source: source, destination: destination))
    }

    /// 执行 /usr/bin/ditto 并把非零退出码转成可读错误。
    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        let text = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw ArchiveError.dittoFailed(text.isEmpty ? "ditto exit \(process.terminationStatus)" : text)
    }
}
