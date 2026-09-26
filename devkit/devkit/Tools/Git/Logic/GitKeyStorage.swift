//
//  GitKeyStorage.swift
//  devkit
//
//  Git 密钥对的文件落盘与生成。私钥（+ 公钥）存进数据目录 git_keys/ 子目录，GitKey 只记相对文件名；
//  与 SSHKeyStorage 同源理念：密钥随数据目录走 → 把数据目录放到同步盘即可跨设备复用同一对密钥。
//
//  生成走系统 /usr/bin/ssh-keygen（产出标准 OpenSSH 格式，git/ssh 直接可用）：
//   - ed25519：`ssh-keygen -t ed25519 -C <comment> -f <file> -N <passphrase>`
//   - rsa：额外 `-b 4096`
//  使用前对私钥 chmod 600（OpenSSH 强制校验权限，同步盘常丢权限位）。
//

import Foundation

@MainActor
enum GitKeyStorage {
    /// 数据目录内存放密钥对的子目录名。
    static let subdirectory = "git_keys"

    // MARK: - 目录 / 路径

    /// git_keys/ 目录 URL；确保存在。数据目录未配置时返回 nil。
    static func keysDirectoryURL(create: Bool = true) -> URL? {
        guard let base = AppPreferences.shared.dataDirectoryURL else { return nil }
        let dir = base.appendingPathComponent(subdirectory, isDirectory: true)
        if create, !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 私钥相对文件名（公钥为其 + ".pub"）。以密钥 id 命名，天然唯一稳定。
    static func privateFileName(for keyID: UUID) -> String {
        "\(keyID.uuidString).key"
    }

    /// 相对文件名 → 数据目录内私钥绝对 URL；文件不存在返回 nil。
    static func resolvedPrivateURL(fileName: String) -> URL? {
        guard let dir = keysDirectoryURL(create: false) else { return nil }
        let url = dir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 私钥 URL 对应的公钥 URL（同目录 <name>.pub）。
    static func publicURL(forPrivate url: URL) -> URL {
        url.appendingPathExtension("pub")
    }

    // MARK: - 生成

    /// 生成一把新密钥对并落进 git_keys/。
    static func generate(name: String,
                         algorithm: GitKeyAlgorithm,
                         comment: String,
                         passphrase: String) async throws -> GitKey {
        guard let dir = keysDirectoryURL() else { throw KeyError.noDataDirectory }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw KeyError.emptyName }

        let keyID = UUID()
        let fileName = privateFileName(for: keyID)
        let privateURL = dir.appendingPathComponent(fileName)

        var args = ["-t", algorithm.sshKeyTypeFlag,
                    "-C", comment,
                    "-f", privateURL.path,
                    "-N", passphrase]
        if let bits = algorithm.bits { args += ["-b", String(bits)] }

        let out = try await GitRunner.run(executable: GitRunner.sshKeygenPath,
                                          arguments: args,
                                          workingDirectory: dir.path)
        guard out.succeeded else {
            try? FileManager.default.removeItem(at: privateURL)
            throw KeyError.generateFailed(out.errorText)
        }

        let pubURL = publicURL(forPrivate: privateURL)
        let publicKey = (try? String(contentsOf: pubURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        applyPermissions(privateURL)

        return GitKey(name: trimmedName,
                      algorithm: algorithm,
                      comment: comment,
                      publicKey: publicKey,
                      privateFileName: fileName,
                      hasPassphrase: !passphrase.isEmpty,
                      imported: false)
    }

    // MARK: - 导入

    /// 从磁盘已有私钥导入：复制私钥进 git_keys/，尽力派生公钥（读同名 .pub 或用 ssh-keygen -y）。
    /// - Parameter sourceURL: NSOpenPanel 选中的私钥文件。
    static func importKey(from sourceURL: URL, name: String) async throws -> GitKey {
        guard let dir = keysDirectoryURL() else { throw KeyError.noDataDirectory }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw KeyError.emptyName }

        let keyID = UUID()
        let fileName = privateFileName(for: keyID)
        let dest = dir.appendingPathComponent(fileName)
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        try data.write(to: dest, options: .atomic)
        applyPermissions(dest)

        // 派生公钥：先看源目录是否已有 .pub；否则用 ssh-keygen -y 计算（带口令的私钥会失败）。
        var publicKey = ""
        let siblingPub = sourceURL.appendingPathExtension("pub")
        if let pub = try? String(contentsOf: siblingPub, encoding: .utf8) {
            publicKey = pub.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let out = try? await GitRunner.run(executable: GitRunner.sshKeygenPath,
                                               arguments: ["-y", "-f", dest.path],
                                               workingDirectory: dir.path)
            if let out, out.succeeded {
                publicKey = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return GitKey(name: trimmedName,
                      algorithm: detectAlgorithm(from: publicKey),
                      comment: "",
                      publicKey: publicKey,
                      privateFileName: fileName,
                      hasPassphrase: false,
                      imported: true)
    }

    /// 从公钥文本粗略判断算法（仅展示用；导入时私钥位数不可靠）。
    static func detectAlgorithm(from publicKey: String) -> GitKeyAlgorithm {
        publicKey.lowercased().contains("rsa") ? .rsa : .ed25519
    }

    // MARK: - 维护

    /// 使用前刷新私钥权限为 0600（同步后权限可能丢失，OpenSSH 会拒用）。
    static func ensureUsable(fileName: String) {
        guard let url = resolvedPrivateURL(fileName: fileName) else { return }
        applyPermissions(url)
    }

    /// 删除某私钥及其公钥文件。
    static func delete(fileName: String) {
        guard let dir = keysDirectoryURL(create: false) else { return }
        let priv = dir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: priv)
        try? FileManager.default.removeItem(at: publicURL(forPrivate: priv))
    }

    private static func applyPermissions(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    enum KeyError: LocalizedError {
        case noDataDirectory, emptyName, generateFailed(String)
        var errorDescription: String? {
            switch self {
            case .noDataDirectory: return "尚未配置数据存储目录"
            case .emptyName: return "密钥名称不能为空"
            case .generateFailed(let m): return "生成密钥失败：\(m)"
            }
        }
    }
}
