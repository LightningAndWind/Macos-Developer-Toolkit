//
//  GitSSHBridge.swift
//  devkit
//
//  把「仓库绑定的密钥」翻译成一次 git 远程操作需要的环境变量：GIT_SSH_COMMAND。
//  关键：不在仓库 .git/config 里写死私钥绝对路径，而是每次运行时按当前设备的 git_keys/ 实际路径拼命令，
//  这样密钥对随同步盘换到另一台设备后仍能命中（真正的跨设备复用）。使用前刷新私钥权限 0600。
//

import Foundation

@MainActor
enum GitSSHBridge {
    /// 依据仓库绑定的 keyID 解析出远程操作环境变量。
    /// - 未绑定 / 私钥文件缺失 → 返回空字典（git 走系统默认：agent、~/.ssh、仓库 config）。
    static func environment(keyID: UUID?) -> [String: String] {
        guard let keyID,
              let key = GitKeyStore.load(id: keyID),
              let fileName = key.privateFileName,
              let url = GitKeyStorage.resolvedPrivateURL(fileName: fileName)
        else { return [:] }

        GitKeyStorage.ensureUsable(fileName: fileName)
        let command = sshCommand(privateKeyPath: url.path)
        return ["GIT_SSH_COMMAND": command]
    }

    /// 拼装 GIT_SSH_COMMAND。路径做 shell 单引号转义（GIT_SSH_COMMAND 由 git 经 shell 解释）。
    /// `IdentitiesOnly=yes` 强制只用这把 key，避免 agent 里其它 key 抢先导致认证错身份。
    static func sshCommand(privateKeyPath: String) -> String {
        "ssh -i \(shellQuoted(privateKeyPath)) -o IdentitiesOnly=yes"
    }

    /// 单引号包裹并转义内部单引号（'\\'' 惯用法）。
    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
