//
//  SSHProfile.swift
//  devkit
//
//  M4：SSH 连接配置的数据模型。仿 HTTP 集合，支持多级文件夹归类。
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

/// 一条 SSH 连接配置。整条以 Codable 编入 `ssh_profiles.profile_json`，
/// 标量列仅作查询/排序冗余（编解码对称：解码一律回到本结构，见 SSHProfileStore）。
struct SSHProfile: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    /// 所属文件夹；`nil` = 根。
    var folderID: UUID?
    var name: String
    var host: String
    var port: Int
    var username: String
    var authKind: SSHAuthKind
    /// 密码认证：明文密码（仅 `authKind == .password` 使用）。
    var password: String?
    /// 私钥认证：数据目录 `ssh_keys/` 内的相对文件名（仅 `authKind == .key` 使用）。
    var privateKeyFileName: String?
    /// 私钥认证：PEM 口令（明文，可选；加密私钥才需要）。
    var keyPassphrase: String?
    var createdAt: Date = .now
    var updatedAt: Date = .now

    static let defaultPort = 22

    /// 展示用的 `user@host:port` 摘要（端口为默认 22 时省略）。
    var connectSummary: String {
        let portPart = port == Self.defaultPort ? "" : ":\(port)"
        return "\(username)@\(host)\(portPart)"
    }
}

/// 一个标签内的终端会话种类：本地 shell 或远程 SSH。
enum SSHSessionKind: String, Codable, Hashable {
    case local
    case remote
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
