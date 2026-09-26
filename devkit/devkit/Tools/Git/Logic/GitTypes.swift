//
//  GitTypes.swift
//  devkit
//
//  Git 命令输出解析后的值类型。全部为 Sendable 结构体：可在后台解析、主 actor 展示。
//

import Foundation

/// 单个文件的变更条目（来自 `git status --porcelain`）。
struct GitFileEntry: Identifiable, Hashable, Sendable {
    /// XY 两位状态码原文。
    let xy: String
    /// 文件路径（重命名时为 "->" 后的新路径）。
    let path: String
    /// 重命名 / 复制的源路径。
    let fromPath: String?

    var id: String { "\(xy) \u{1}\(path)" }

    /// 索引状态（X）。
    var indexStatus: Character { xy.first ?? " " }
    /// 工作区状态（Y）。
    var workStatus: Character { xy.count >= 2 ? xy[xy.index(xy.startIndex, offsetBy: 1)] : " " }

    var untracked: Bool { xy == "??" }
    var ignored: Bool { xy == "!!" }
    var conflicted: Bool {
        // porcelain v1 冲突态：UU / AA / DD，或任一位置为 U。
        xy.contains("U") || xy == "AA" || xy == "DD"
    }
    /// 是否已暂存（索引里有改动，X 非空格且非 '?'）。
    var isStaged: Bool { indexStatus != " " && indexStatus != "?" }
    /// 工作区是否有未暂存改动（Y 非空格且非 '?'）。
    var hasUnstaged: Bool { workStatus != " " && workStatus != "?" }

    var badge: String {
        switch workStatus == " " ? indexStatus : workStatus {
        case "M": return "修改"
        case "A": return "新增"
        case "D": return "删除"
        case "R": return "重命名"
        case "C": return "复制"
        case "?": return "未跟踪"
        case "U": return "冲突"
        default: return "变更"
        }
    }
}

/// 仓库工作区状态。
struct GitStatus: Sendable {
    var branch: String
    var upstream: String?
    var ahead: Int
    var behind: Int
    var entries: [GitFileEntry]
    /// 变基进行中（`## HEAD (no branch)` 且检测到 rebase 目录时置位，UI 用于提示）。
    var isRebasing: Bool

    static let empty = GitStatus(branch: "—", upstream: nil, ahead: 0, behind: 0, entries: [], isRebasing: false)

    var conflicted: [GitFileEntry] { entries.filter { $0.conflicted } }
    var staged: [GitFileEntry] { entries.filter { $0.isStaged && !$0.conflicted } }
    var unstaged: [GitFileEntry] { entries.filter { $0.hasUnstaged && !$0.conflicted } }
    var untracked: [GitFileEntry] { entries.filter { $0.untracked } }
    var isClean: Bool { entries.isEmpty }
}

/// 一个分支引用。
struct GitBranch: Identifiable, Hashable, Sendable {
    var name: String
    var isCurrent: Bool
    var isRemote: Bool
    var id: String { "\(isRemote ? "r" : "l"):\(name)" }
}

/// 一条提交记录。
struct GitCommit: Identifiable, Hashable, Sendable {
    var hash: String
    var shortHash: String
    var author: String
    var relativeDate: String
    var refs: String
    var subject: String
    var id: String { hash }
}

/// 一个远程仓库（`git remote -v` 聚合）。
struct GitRemote: Identifiable, Hashable, Sendable {
    var name: String
    var fetchURL: String?
    var pushURL: String?
    var id: String { name }
    var displayURL: String { fetchURL ?? pushURL ?? "—" }
}

/// 一条 stash 记录。
struct GitStashEntry: Identifiable, Hashable, Sendable {
    var index: Int
    var message: String
    var id: Int { index }
}

/// 一个标签。
struct GitTag: Identifiable, Hashable, Sendable {
    var name: String
    var id: String { name }
}
