//
//  TerminalNote.swift
//  devkit
//
//  终端记事本：一条 = 一段可随手发到当前终端执行的命令/文本（标题 + 内容）。
//  按 SSH 会话记录（profile）分类归属：`profileID` 指向所属记录（本地 / 远程记录皆可），
//  nil = 未分类（临时会话 / 未选择会话时的默认桶）。执行不受分类限制 —— 面板里任何
//  分类的记事都发往**当前**终端（跨记录复用命令片段正是分类浏览的意义）。
//  持久化在 SQLite 的 terminal_notes 表。
//

import Foundation

struct TerminalNote: Identifiable, Equatable {
    let id: UUID
    /// 所属 SSH 记录（分类）；nil = 未分类。
    var profileID: UUID?
    var title: String
    var content: String
    let createdAt: Date
    var updatedAt: Date

    /// 标题空白时列表里的占位名。
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名记事" : trimmed
    }

    /// 内容去除首尾空白后是否可执行（空内容不发送）。
    var executableBody: String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
