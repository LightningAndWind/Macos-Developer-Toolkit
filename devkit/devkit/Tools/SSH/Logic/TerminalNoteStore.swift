//
//  TerminalNoteStore.swift
//  devkit
//
//  终端记事本存储：@Observable 单例，视图直接读 `notes` 获得跨标签实时同步。
//  记事按 SSH 会话记录（profileID）分类；nil = 未分类（临时会话 / 未选择会话的默认桶）。
//  复用 DatabaseManager 的 terminal_notes 表；db 未打开时静默降级（与 SSHProfileStore 一致）。
//  列表按 created_at 倒序：新记事插入到顶部可见，编辑/改名不打乱既有位置。
//  面板按分类过滤展示；执行不受分类限制（任何分类的记事都发往当前终端）。
//

import Foundation

@MainActor
@Observable
final class TerminalNoteStore {
    static let shared = TerminalNoteStore()

    /// 全部记事（新在前，不分分类）；懒加载：面板首次出现时 `loadIfNeeded()`。
    private(set) var notes: [TerminalNote] = []
    private var loaded = false

    private init() {}

    // MARK: - 读取

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    func reload() {
        guard DatabaseManager.shared.isOpen else { notes = []; return }
        var results: [TerminalNote] = []
        try? DatabaseManager.shared.query(
            "SELECT id, profile_id, title, content, created_at, updated_at FROM terminal_notes ORDER BY created_at DESC;"
        ) { row in
            guard let id = UUID(uuidString: row.text(0) ?? ""),
                  let title = row.text(2),
                  let content = row.text(3)
            else { return true }
            results.append(TerminalNote(id: id,
                                        profileID: row.text(1).flatMap { UUID(uuidString: $0) },
                                        title: title,
                                        content: content,
                                        createdAt: Date(timeIntervalSince1970: row.real(4)),
                                        updatedAt: Date(timeIntervalSince1970: row.real(5))))
            return true
        }
        notes = results
    }

    /// 某个分类（SSH 记录）下的记事；`profileID == nil` 为未分类。
    func notes(inProfile profileID: UUID?) -> [TerminalNote] {
        notes.filter { $0.profileID == profileID }
    }

    // MARK: - 写入

    /// 在指定分类下新建一条空白记事；db 未打开返回 nil。
    @discardableResult
    func create(profileID: UUID? = nil) -> TerminalNote? {
        guard DatabaseManager.shared.isOpen else { return nil }
        let note = TerminalNote(id: UUID(), profileID: profileID, title: "", content: "",
                                createdAt: .now, updatedAt: .now)
        try? DatabaseManager.shared.run(
            "INSERT INTO terminal_notes(id, profile_id, title, content, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?);",
            bind: [.text(note.id.uuidString),
                   note.profileID.map { SQLiteValue.text($0.uuidString) } ?? .null,
                   .text(note.title), .text(note.content),
                   .real(note.createdAt.timeIntervalSince1970), .real(note.updatedAt.timeIntervalSince1970)]
        )
        reload()
        return note
    }

    /// 改标题（空白标题展示时回落为「未命名记事」，存储保留原文）。
    func rename(id: UUID, title: String) {
        guard var note = self.note(id: id) else { return }
        guard note.title != title else { return }
        note.title = title
        note.updatedAt = .now
        persist(note)
    }

    /// 改内容（编辑器每次变更即写穿，崩溃/关闭也不丢）。
    func updateContent(id: UUID, content: String) {
        guard var note = self.note(id: id) else { return }
        guard note.content != content else { return }
        note.content = content
        note.updatedAt = .now
        persist(note)
    }

    func delete(id: UUID) {
        guard DatabaseManager.shared.isOpen else { return }
        try? DatabaseManager.shared.run("DELETE FROM terminal_notes WHERE id = ?;",
                                        bind: [.text(id.uuidString)])
        reload()
    }

    /// 删除某个 SSH 记录（分类）下的全部记事 —— 供记录删除时级联清理。
    func deleteAll(inProfile profileID: UUID) {
        guard DatabaseManager.shared.isOpen else { return }
        try? DatabaseManager.shared.run("DELETE FROM terminal_notes WHERE profile_id = ?;",
                                        bind: [.text(profileID.uuidString)])
        reload()
    }

    // MARK: - 内部

    private func note(id: UUID) -> TerminalNote? {
        notes.first { $0.id == id }
    }

    private func persist(_ note: TerminalNote) {
        guard DatabaseManager.shared.isOpen else { return }
        try? DatabaseManager.shared.run(
            "UPDATE terminal_notes SET title = ?, content = ?, updated_at = ? WHERE id = ?;",
            bind: [.text(note.title), .text(note.content),
                   .real(note.updatedAt.timeIntervalSince1970), .text(note.id.uuidString)]
        )
        reload()
    }
}
