//
//  GitModels.swift
//  devkit
//
//  Git 管理工具的数据模型。仿 SSH 的「多级文件夹 + 条目」集合范式：
//  - GitFolder / GitRepo：仓库按路径 + 别名登记，可多级文件夹归类（对照 SSHFolder / SSHProfile）。
//  - GitKey：独立的一等密钥对实体，可被多个仓库引用（不同于 SSH 把私钥内嵌进 profile）。
//  凭据策略与 SSH 一致：公钥文本随 GitKey 存入 SQLite；私钥本体（PEM）不入库，
//  落进数据目录 git_keys/ 内，GitKey 只记相对文件名。跨设备依赖「数据目录本身被同步」。
//

import Foundation

/// 密钥算法。ed25519 为默认推荐；rsa 兼容老服务器。
enum GitKeyAlgorithm: String, CaseIterable, Codable, Hashable {
    case ed25519
    case rsa

    var label: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .rsa: return "RSA 4096"
        }
    }

    /// ssh-keygen `-t` 参数值。
    var sshKeyTypeFlag: String {
        switch self {
        case .ed25519: return "ed25519"
        case .rsa: return "rsa"
        }
    }

    /// ssh-keygen `-b` 位数（ed25519 固定，无需传）。
    var bits: Int? {
        switch self {
        case .ed25519: return nil
        case .rsa: return 4096
        }
    }
}

/// Git 集合文件夹（支持多级）。`parentID == nil` 表示位于根。对照 SSHFolder。
struct GitFolder: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var parentID: UUID?
    var name: String
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

/// 一把 SSH 密钥对。整条以 Codable 编入 `git_keys.key_json`，标量列仅作查询/排序冗余。
struct GitKey: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var algorithm: GitKeyAlgorithm
    /// 密钥注释（通常是邮箱 / 用途标识），写入 ssh-keygen `-C`。
    var comment: String
    /// 公钥全文（`ssh-ed25519 AAAA... comment`），用于展示与复制到 GitHub/GitLab。
    var publicKey: String
    /// 私钥在数据目录 git_keys/ 内的相对文件名；导入失败或未落盘时为 nil。
    var privateFileName: String?
    /// 私钥是否带口令保护。
    var hasPassphrase: Bool
    /// 是否为从磁盘导入（区别于应用内生成）。
    var imported: Bool
    var createdAt: Date = .now
    var updatedAt: Date = .now

    /// 展示用的短指纹：公钥主体前若干字符，避免整串刷屏。
    var fingerprintHint: String {
        let parts = publicKey.split(separator: " ")
        guard parts.count >= 2 else { return publicKey.prefix(16) + "…" }
        return "\(parts[0]) \(parts[1].prefix(12))…"
    }
}

/// 一个已登记的 Git 仓库。整条编入 `git_repos.repo_json`。
struct GitRepo: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    /// 所属文件夹；`nil` = 根。
    var folderID: UUID?
    /// 别名（用户可识别的名字）。
    var alias: String
    /// 仓库工作目录绝对路径。
    var path: String
    /// 绑定使用的密钥；`nil` 表示走系统默认（agent / ~/.ssh / 仓库 config）。
    var keyID: UUID?
    var createdAt: Date = .now
    var updatedAt: Date = .now

    /// 路径目录是否存在（工作目录可能被移动 / 换设备后路径改变）。
    var isValid: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 展示用的目录末段名（真实文件夹名），与别名不同才补充显示。
    var directoryName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

/// 集合树节点，供侧栏 / 选择器渲染。文件夹可含子文件夹与仓库，仓库为叶子。对照 SSHCollectionNode。
struct GitCollectionNode: Identifiable {
    enum Kind {
        case folder(GitFolder)
        case repo(GitRepo)
    }

    var id: UUID
    var kind: Kind
    var children: [GitCollectionNode]?

    init(id: UUID, kind: Kind, children: [GitCollectionNode]? = nil) {
        self.id = id
        self.kind = kind
        self.children = children
    }

    var name: String {
        switch kind {
        case .folder(let f): return f.name
        case .repo(let r): return r.alias
        }
    }

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }
}
