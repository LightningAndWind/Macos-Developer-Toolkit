//
//  SSHKeyStorage.swift
//  devkit
//
//  M4：SSH 私钥文件落盘。用户经 NSOpenPanel 选择的 PEM 复制到数据目录（首屏引导选择的
//  文件夹）下的 ssh_keys/ 子目录，profile 只记录相对文件名；连接时从数据目录本地读取，
//  不再依赖原路径。删除 profile 时一并清除其私钥文件。
//

import Foundation

/// 私钥文件存储（仅在主 actor 使用；数据目录未配置时静默降级）。
@MainActor
enum SSHKeyStorage {
    /// 数据目录内存放私钥的子目录名。
    static let subdirectory = "ssh_keys"

    /// ssh_keys/ 目录 URL；确保存在。数据目录未配置时返回 nil。
    static func keysDirectoryURL(create: Bool = true) -> URL? {
        guard let base = AppPreferences.shared.dataDirectoryURL else { return nil }
        let dir = base.appendingPathComponent(subdirectory, isDirectory: true)
        if create, !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 依据 profile id 生成稳定且唯一的存储文件名。
    static func fileName(for profileID: UUID) -> String {
        "\(profileID.uuidString).pem"
    }

    /// 读取用户所选私钥文件内容并复制到数据目录 ssh_keys/。返回相对文件名。
    /// - Parameter sourceURL: NSOpenPanel 选中的文件（user-selected 权限可读）。
    @discardableResult
    static func copyIn(from sourceURL: URL, profileID: UUID) throws -> String {
        guard let dir = keysDirectoryURL() else {
            throw KeyError.noDataDirectory
        }
        // NSOpenPanel 选择的文件具备 user-selected 读权限，直接读取其字节。
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let name = fileName(for: profileID)
        let dest = dir.appendingPathComponent(name)
        try data.write(to: dest, options: .atomic)
        // OpenSSH 对 `-i` 私钥强制校验权限，过宽会报 “UNPROTECTED PRIVATE KEY FILE” 拒用；限为 0600。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        return name
    }

    /// 相对文件名 → 数据目录内绝对 URL（供连接时读取）。文件不存在返回 nil。
    static func resolvedURL(fileName: String) -> URL? {
        guard let dir = keysDirectoryURL(create: false) else { return nil }
        let url = dir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 删除某相对文件名对应的私钥文件。
    static func delete(fileName: String) {
        guard let dir = keysDirectoryURL(create: false) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
    }

    enum KeyError: LocalizedError {
        case noDataDirectory
        var errorDescription: String? {
            switch self {
            case .noDataDirectory: return "尚未配置数据存储目录"
            }
        }
    }
}
