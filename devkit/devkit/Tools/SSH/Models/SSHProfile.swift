//
//  SSHProfile.swift
//  devkit
//
//  M4：终端会话记录的数据模型。仿 HTTP 集合，支持多级文件夹归类。
//  一条记录既可以是远程 SSH 主机（.remote），也可以是本地终端（.local）；
//  两者都能配置「默认进入的文件夹」（workingDirectory），打开即落在该目录。
//  凭据（密码 / 私钥 passphrase）按用户指定以明文随 profile 存入 SQLite；
//  私钥本体（PEM）不入库，复制到数据目录 ssh_keys/ 内，profile 只存相对文件名。
//

import Foundation

/// 认证方式。
enum SSHAuthKind: String, CaseIterable, Codable, Hashable {
    case password
    case key

    var label: String {
        switch self {
        case .password: return "密码"
        case .key: return "私钥"
        }
    }
}

/// SSH 集合文件夹（支持多级）。`parentID == nil` 表示位于根。
struct SSHFolder: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var parentID: UUID?
    var name: String
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

/// 一条终端会话记录。整条以 Codable 编入 `ssh_profiles.profile_json`，
/// 标量列仅作查询/排序冗余（编解码对称：解码一律回到本结构，见 SSHProfileStore）。
///
/// 会话类型 `kind`：
/// - `.remote`：远程 SSH 主机（`host` / `port` / `username` / `authKind` 有意义）；
/// - `.local`：本机终端（只用 `name` / `workingDirectory`，其余字段忽略）。
///
/// 迁移说明：`kind` 与 `workingDirectory` 是后补字段，旧数据 JSON 里没有这两个键。
/// 若交给合成解码，会因 `keyNotFound` 抛错、被 `try?` 吞掉 → 旧记录在界面上静默消失。
/// 故此处自定义 `init(from:)`（见文件末尾扩展），对这两个字段走 `decodeIfPresent`。
struct SSHProfile: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    /// 所属文件夹；`nil` = 根。
    var folderID: UUID?
    /// 会话类型：本地终端 / 远程 SSH。
    var kind: SSHSessionKind = .remote
    var name: String
    /// 默认进入的文件夹：
    /// - `.local`：本机绝对路径（打开终端即以该目录为工作目录）；
    /// - `.remote`：远端路径（登录成功后自动 `cd` 过去）。
    /// `nil` / 空白 → 本地进个人目录，远程不切换目录。
    var workingDirectory: String?
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var authKind: SSHAuthKind = .password
    /// 密码认证：明文密码（仅 `authKind == .password` 使用）。
    var password: String?
    /// 私钥认证：数据目录 `ssh_keys/` 内的相对文件名（仅 `authKind == .key` 使用）。
    var privateKeyFileName: String?
    /// 私钥认证：PEM 口令（明文，可选；加密私钥才需要）。
    var keyPassphrase: String?
    var createdAt: Date = .now
    var updatedAt: Date = .now

    static let defaultPort = 22

    // MARK: - 派生

    /// 是否为本地终端记录。
    var isLocal: Bool { kind == .local }
    /// 是否为远程 SSH 记录。
    var isRemote: Bool { kind == .remote }

    /// 去除首尾空白后的默认目录；空串一律视为「未设置」。
    var normalizedWorkingDirectory: String? {
        guard let dir = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dir.isEmpty else { return nil }
        return dir
    }

    /// 展示用的 `user@host:port` 摘要（端口为默认 22 时省略）。
    var connectSummary: String {
        let portPart = port == Self.defaultPort ? "" : ":\(port)"
        return "\(username)@\(host)\(portPart)"
    }

    /// 列表 / 树中展示的副标题：远程显示 `user@host`，本地显示目录（home 缩写为 `~`）。
    var displaySummary: String {
        guard isLocal else { return connectSummary }
        guard let dir = normalizedWorkingDirectory else { return "本地终端 · 个人目录" }
        return Self.abbreviateHome(dir)
    }

    /// 远端登录后进入默认目录的整段远程命令（供外部 `ssh` 子进程作为远程命令使用）。
    /// 用 `;` 而非 `&&`：目录不存在时也照常进入 shell，不至于把会话直接顶掉。
    var sshRemoteCommand: String? {
        guard isRemote, let dir = normalizedWorkingDirectory else { return nil }
        return "cd \(Self.shellQuote(dir)); exec \"$SHELL\" -l"
    }

    /// 远端登录后要发送的 `cd` 命令（供进程内 NIOSSH 引擎在会话建立后写入）。
    var remoteChangeDirectoryCommand: String? {
        guard isRemote, let dir = normalizedWorkingDirectory else { return nil }
        return "cd \(Self.shellQuote(dir))"
    }

    // MARK: - 工具方法

    /// 把本机 home 前缀缩写为 `~`，仅用于界面展示。
    static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// POSIX 单引号转义：把任意路径安全地拼进远端 shell 命令行。
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - 兼容旧数据的解码

extension SSHProfile {
    /// 自定义解码（放在扩展里，保留编译器合成的逐成员初始化器）。
    /// 后补字段 `kind` / `workingDirectory` 用 `decodeIfPresent` 兜底，其余字段维持严格解码。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        kind = try c.decodeIfPresent(SSHSessionKind.self, forKey: .kind) ?? .remote
        name = try c.decode(String.self, forKey: .name)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        authKind = try c.decode(SSHAuthKind.self, forKey: .authKind)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        privateKeyFileName = try c.decodeIfPresent(String.self, forKey: .privateKeyFileName)
        keyPassphrase = try c.decodeIfPresent(String.self, forKey: .keyPassphrase)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

/// 一个标签内的终端会话种类：本地 shell 或远程 SSH。
enum SSHSessionKind: String, Codable, Hashable {
    case local
    case remote

    var label: String {
        switch self {
        case .local: return "本地终端"
        case .remote: return "远程 SSH"
        }
    }
}

/// 连接状态机。
enum SSHConnectionState: Equatable {
    case idle
    case connecting
    case connected(host: String)
    case failed(String)
    case disconnected

    var isLive: Bool {
        switch self {
        case .connecting, .connected: return true
        default: return false
        }
    }
}

/// 集合树节点，供选择器 / 侧栏渲染。文件夹可含子文件夹与连接，连接为叶子。
struct SSHCollectionNode: Identifiable {
    enum Kind {
        case folder(SSHFolder)
        case profile(SSHProfile)
    }

    var id: UUID
    var kind: Kind
    var children: [SSHCollectionNode]?

    init(id: UUID, kind: Kind, children: [SSHCollectionNode]? = nil) {
        self.id = id
        self.kind = kind
        self.children = children
    }

    var name: String {
        switch kind {
        case .folder(let f): return f.name
        case .profile(let p): return p.name
        }
    }

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }
}
