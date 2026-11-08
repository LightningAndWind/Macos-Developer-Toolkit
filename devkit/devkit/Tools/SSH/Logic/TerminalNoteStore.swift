//
//  TerminalNoteStore.swift
//  devkit
//
//  终端记事本存储：@Observable 单例，视图直接读 `notes(inProfile:)` 获得跨标签实时同步。
//  记事按 SSH 会话记录（profileID）分类；nil = 未分类（临时会话 / 未选择会话的默认桶）。
//  复用 DatabaseManager 的 terminal_notes 表；db 未打开时静默降级（与 SSHProfileStore 一致）。
//  列表按 created_at 倒序：新记事插入到顶部可见，编辑/改名不打乱既有位置。
//  面板按分类过滤展示；执行不受分类限制（任何分类的记事都发往当前终端）。
//
//  ## 为什么用 revision + @ObservationIgnored 存储
//  @Observable 对数组属性是「整体依赖」：哪怕只是 `notes[index] = note` 这种原地替换，
//  所有读过 notes 的视图都会失效。旧实现里每次击键都写穿并替换元素，于是整个面板
//  （分类选择器、所有行、TextEditor 的 AppKit 桥接）每敲一个字就重算一遍 body，
//  这是编辑器粘滞的根因。
//  现在把真实存储放到 @ObservationIgnored 的 storage 中，只有「列表组成变化」
//  （载入 / 新建 / 删除 / 级联清理）才递增 revision；标题与内容写穿只静默更新
//  storage + 落库，不广播。行视图的标题/内容本就由本地草稿驱动，因此显示不会滞后。
//

import Foundation
import Observation

@MainActor
@Observable
final class TerminalNoteStore {
    static let shared = TerminalNoteStore()

    /// 列表结构版本。`notes(inProfile:)` 会读它，从而让调用方（SwiftUI body）登记依赖。
    /// 编辑类写穿**不**递增，保证高频输入不触发任何视图重算。
    private(set) var revision = 0

    /// 真实存储（新在前，不分分类）。编辑写穿在这里静默生效。
    @ObservationIgnored private var storage: [TerminalNote] = []
    @ObservationIgnored private var loaded = false

    private init() {}

    /// 只读快照，供自检 / 非视图逻辑使用。
    var notes: [TerminalNote] { storage }

    // MARK: - 读取

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    func reload() {
        storage = fetchAll()
        revision += 1
    }

    /// 某个分类（SSH 记录）下的记事；`profileID == nil` 为未分类。
    ///
    /// 这里显式读一次 revision：Observation 的依赖登记基于线程本地的 access 记录，
    /// 与调用栈无关，所以视图在 body 里调用本方法就会自动订阅结构变更。
    /// `guard` 分支恒不成立，但能确保带观察副作用的 getter 不被编译器当作死代码消除。
    func notes(inProfile profileID: UUID?) -> [TerminalNote] {
        let version = revision
        guard version >= 0 else { return [] }
        return storage.filter { $0.profileID == profileID }
    }

    /// 按 id 取最新值（删除确认文案等需要刚编辑过的标题）。
    func note(id: UUID) -> TerminalNote? {
        storage.first { $0.id == id }
    }

    private func fetchAll() -> [TerminalNote] {
        guard DatabaseManager.shared.isOpen else { return [] }
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
        return results
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
        guard let index = storage.firstIndex(where: { $0.id == id }),
              storage[index].title != title else { return }
        storage[index].title = title
        storage[index].updatedAt = .now
        persist(storage[index])
    }

    /// 改内容（编辑器每次变更即写穿，崩溃/关闭也不丢）。
    func updateContent(id: UUID, content: String) {
        guard let index = storage.firstIndex(where: { $0.id == id }),
              storage[index].content != content else { return }
        storage[index].content = content
        storage[index].updatedAt = .now
        persist(storage[index])
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

    /// 只落库，不改 revision：标题 / 内容是「每次击键一次写穿」，
    /// 任何一次观察广播都会让整个面板（含分类选择器、其余所有行）在击键路径上重渲染。
    private func persist(_ note: TerminalNote) {
        guard DatabaseManager.shared.isOpen else { return }
        try? DatabaseManager.shared.run(
            "UPDATE terminal_notes SET title = ?, content = ?, updated_at = ? WHERE id = ?;",
            bind: [.text(note.title), .text(note.content),
                   .real(note.updatedAt.timeIntervalSince1970), .text(note.id.uuidString)]
        )
    }
}
