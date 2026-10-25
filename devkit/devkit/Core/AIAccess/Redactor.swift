//
//  Redactor.swift
//  devkit
//
//  AI 接入的脱敏层：把「不应进入模型上下文」的字符串从一切出站文本中擦除。
//  覆盖范围 = 全部 SSH 记录的 host / 用户名 / 密码 / 私钥口令 / 私钥文件路径，
//  加上数据目录路径（含本机用户名）与 URL 内嵌凭据（https://user:pass@host）。
//
//  每次调用现查现拼（本地 SQLite 读取成本可忽略），不缓存——记录改动后立即生效。
//  说明：这是「上下文卫生」层而非安全边界：模型输出的命令本身可能打印主机名等信息，
//  这里做的是把已知秘密从结果文本里替换为 [REDACTED]，保证凭据不流入对话记录。
//

import Foundation

@MainActor
enum Redactor {
    /// 替换占位符。
    static let placeholder = "[REDACTED]"

    /// 对外暴露前擦除文本中的敏感字符串。extra 用于补充调用点已知的秘密。
    static func redact(_ text: String, extra: [String] = []) -> String {
        var secrets = knownSecrets() + extra.filter { !$0.isEmpty }
        secrets.sort { $0.count > $1.count } // 长的先替换，避免短串先命中破坏长串

        var result = text
        for secret in secrets where secret.count >= 3 {
            guard secret != placeholder else { continue }
            if result.contains(secret) {
                result = result.replacingOccurrences(of: secret, with: placeholder)
            }
        }
        // 1-2 字符的秘密单独处理（过短不宜全局替换，但密码再短也要擦）：
        // 仅当它前后都不是字母数字时才替换，避免把普通单词打碎。
        for secret in secrets where secret.count > 0 && secret.count < 3 {
            guard secret != placeholder else { continue }
            result = replaceStandaloneShort(result, secret)
        }
        return redactURLCredentials(result)
    }

    /// 当前应被视为秘密的字符串集合。
    static func knownSecrets() -> [String] {
        var secrets: [String] = []

        for profile in SSHProfileStore.allRequests() {
            if profile.host.count >= 3 { secrets.append(profile.host) }
            if profile.username.count >= 3 { secrets.append(profile.username) }
            if let password = profile.password, !password.isEmpty { secrets.append(password) }
            if let passphrase = profile.keyPassphrase, !passphrase.isEmpty { secrets.append(passphrase) }
            if let fileName = profile.privateKeyFileName,
               let url = SSHKeyStorage.resolvedURL(fileName: fileName) {
                secrets.append(url.path)
            }
        }

        for key in GitKeyStore.all() {
            if let fileName = key.privateFileName,
               let url = GitKeyStorage.resolvedPrivateURL(fileName: fileName) {
                secrets.append(url.path)
            }
        }

        for connection in DBConnectionStore.all() {
            if connection.host.count >= 3 { secrets.append(connection.host) }
            if let username = connection.normalizedUsername, username.count >= 3 { secrets.append(username) }
            if let password = connection.normalizedPassword { secrets.append(password) }
        }

        if let dir = AppPreferences.shared.dataDirectoryURL, dir.path.count >= 8 {
            secrets.append(dir.path)
        }

        return secrets
    }

    /// `https://user:pass@host/...` → `https://[REDACTED]@host/...`（git remote 等场景）。
    private static func redactURLCredentials(_ text: String) -> String {
        guard text.contains("://"), text.contains("@") else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"([a-zA-Z][a-zA-Z0-9+.-]*://)[^\s/@:]+:[^\s/@]+@"#) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range,
                                              withTemplate: "$1\(placeholder)@")
    }

    /// 短秘密的保守替换：仅替换前后都不是字母/数字的独立出现。
    private static func replaceStandaloneShort(_ text: String, _ secret: String) -> String {
        var result = ""
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: secret, range: searchRange) {
            result += text[searchRange.lowerBound..<found.lowerBound]
            let prevIsWord = found.lowerBound > text.startIndex &&
                isWordChar(text[text.index(before: found.lowerBound)])
            let nextIsWord = found.upperBound < text.endIndex &&
                isWordChar(text[found.upperBound])
            result += (prevIsWord || nextIsWord) ? secret : placeholder
            searchRange = found.upperBound..<text.endIndex
        }
        result += text[searchRange.lowerBound..<text.endIndex]
        return result
    }

    private static func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }
}
