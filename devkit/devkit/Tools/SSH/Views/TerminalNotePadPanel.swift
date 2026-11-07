//
//  TerminalNotePadPanel.swift
//  devkit
//
//  终端记事本右侧面板：记事按 SSH 会话记录分类的片段库（SQLite 持久化）。
//  顶部分类切换器默认选中**当前会话的记录**，可切到其他记录（含未分类）查看其记事 ——
//  执行不受分类限制，任何记事都发往**当前**终端（跨记录复用片段正是分类浏览的意义）。
//  支持：新建（落入选中分类）/ 删除（「更多」菜单内，二次确认）/ 双击改标题 / 展开编辑内容。
//  手风琴式展开：同一时刻只展开一条，展开态即编辑态。
//  行交互：单击行任意处（含箭头/标题区）展开收起，双击标题重命名；编辑器可放大（行内高度 + 面板整体宽度一起放大）。
//

import SwiftUI

struct TerminalNotePadPanel: View {
    let inputHub: TerminalInputHub
    /// 当前会话来源的 SSH 记录（分类归属与默认视图的依据）；nil = 临时会话 / 未选择 → 未分类。
    let currentProfileID: UUID?
    /// 编辑器放大态（由 SSHToolView 持有：放大时面板整体宽度也要加宽，状态须在其上）。
    let editorEnlarged: Bool
    var onToggleEditorEnlarged: () -> Void = {}

    @State private var store = TerminalNoteStore.shared
    /// 正在查看的分类（SSH 记录 id）；nil = 未分类。默认跟随当前会话记录。
    @State private var selectedProfileID: UUID?
    /// 当前展开（可编辑内容）的记事；nil = 全部收起。
    @State private var expandedID: UUID?
    /// 待删除确认的记事（confirmationDialog 以此驱动）。
    @State private var pendingDeleteID: UUID?
    /// 底部提示条文案（执行成功 / 失败），几秒后自动消失。
    @State private var flash: Flash?
    @State private var flashTask: Task<Void, Never>?

    struct Flash: Equatable {
        let text: String
        let isError: Bool
    }

    init(inputHub: TerminalInputHub, currentProfileID: UUID?,
         editorEnlarged: Bool = false, onToggleEditorEnlarged: @escaping () -> Void = {}) {
        self.inputHub = inputHub
        self.currentProfileID = currentProfileID
        self.editorEnlarged = editorEnlarged
        self.onToggleEditorEnlarged = onToggleEditorEnlarged
        _selectedProfileID = State(initialValue: currentProfileID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            categoryPicker
            noteList
            footer
        }
        .padding(10)
        .onAppear { store.loadIfNeeded() }
        // 会话换了记录（换目标 / 打开另一条记录）时，视图默认跟随到新记录的分类。
        .onChange(of: currentProfileID) { _, new in selectedProfileID = new }
        .confirmationDialog("删除记事本？", isPresented: Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )) {
            Button("删除", role: .destructive) { confirmDelete() }
            Button("取消", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text(String(format: L("「%@」将被删除，无法撤销。"), String(pendingDeleteTitle)))
        }
    }

    /// 当前分类下的记事。
    private var visibleNotes: [TerminalNote] {
        store.notes(inProfile: selectedProfileID)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 6) {
            Text("记事本")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            iconButton("plus", "在当前分类新建记事") { createNote() }
        }
    }

    /// 分类切换器：未分类 + 全部 SSH 记录（本地 / 远程），默认选中当前会话的记录。
    private var categoryPicker: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Picker("分类", selection: $selectedProfileID) {
                Text("未分类").tag(UUID?.none)
                ForEach(recordOptions) { profile in
                    Text(profile.name).tag(UUID?.some(profile.id))
                }
            }
            .labelsHidden()
            .font(.system(size: 12))
            .controlSize(.small)
        }
    }

    /// 分类候选记录：全部会话记录按名排序。直接在 body 里取（SQLite 查询极轻），
    /// 保证删除 / 新建记录后面板分类即时刷新，不引入第二份需手动同步的状态。
    private var recordOptions: [SSHProfile] {
        SSHProfileStore.allRequests()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: 列表

    private var noteList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(visibleNotes) { note in
                    TerminalNoteRow(note: note,
                                    store: store,
                                    inputHub: inputHub,
                                    isExpanded: expandedID == note.id,
                                    isEditorEnlarged: editorEnlarged,
                                    onToggleExpand: { toggleExpand(note) },
                                    onToggleEditorEnlarged: onToggleEditorEnlarged,
                                    onRequestDelete: { pendingDeleteID = note.id },
                                    onExecuted: { ok in reportExecution(ok) })
                }
            }
            .padding(.vertical, 2)
            // 右侧留余量：避免行尾按钮与自绘滚动指示条重叠。
            .padding(.trailing, 8)
        }
        .scrollIndicators(.never)
        .scrollIndicatorBar()
        .overlay {
            if visibleNotes.isEmpty {
                Text("当前分类暂无记事\n点右上角 + 新建")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Text(String(format: L("%@ 条"), String(visibleNotes.count)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let flash {
                Text(flash.text)
                    .font(.caption)
                    .foregroundStyle(flash.isError ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.micro, value: flash)
    }

    // MARK: 动作

    private func createNote() {
        // 新增默认落入**当前选中的分类**（初始为当前会话的记录）。
        guard let note = store.create(profileID: selectedProfileID) else {
            showMessage(Flash(text: "数据库未打开，无法新建", isError: true))
            return
        }
        // 展开即编辑：行内编辑器 onAppear 自动聚焦（见 TerminalNoteRow.contentEditor）。
        withAnimation(Theme.Motion.micro) { expandedID = note.id }
    }

    private func toggleExpand(_ note: TerminalNote) {
        withAnimation(Theme.Motion.micro) {
            expandedID = (expandedID == note.id) ? nil : note.id
        }
    }

    private func confirmDelete() {
        guard let id = pendingDeleteID else { return }
        if expandedID == id { withAnimation(Theme.Motion.micro) { expandedID = nil } }
        store.delete(id: id)
        pendingDeleteID = nil
        showMessage(Flash(text: "已删除", isError: false))
    }

    private func reportExecution(_ ok: Bool) {
        showMessage(ok ? Flash(text: "已发送到终端", isError: false)
                       : Flash(text: "终端未连接，无法执行", isError: true))
    }

    private func showMessage(_ message: Flash) {
        flashTask?.cancel()
        flash = message
        flashTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.Motion.micro) { flash = nil }
        }
    }

    private var pendingDeleteTitle: String {
        visibleNotes.first { $0.id == pendingDeleteID }?.displayTitle ?? "未命名记事"
    }

    private func iconButton(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(tip)
    }
}

// MARK: - 记事行

/// 一条记事：标题行（展开箭头 + 标题 + 执行 + 更多菜单）+ 展开态的内容编辑器。
/// 行交互：单击箭头/标题区展开收起，双击标题重命名（编辑态内 TextField 自管点击）。
/// 标题/内容草稿存本地 @State，变更即写穿到 store（跨标签共享同一 SQLite 数据源）。
private struct TerminalNoteRow: View {
    let note: TerminalNote
    let store: TerminalNoteStore
    let inputHub: TerminalInputHub
    let isExpanded: Bool
    /// 编辑器放大态（面板级：放大时整个面板一起加宽，状态由上层持有）。
    let isEditorEnlarged: Bool
    var onToggleExpand: () -> Void
    var onToggleEditorEnlarged: () -> Void
    var onRequestDelete: () -> Void
    var onExecuted: (_ ok: Bool) -> Void

    @State private var titleDraft: String
    /// 标题重命名态（双击进入；提交/取消退出）。默认态标题为纯展示 Text，避免单击就进编辑。
    @State private var isEditingTitle = false
    @State private var contentDraft: String
    @FocusState private var editorFocused: Bool
    @FocusState private var titleFieldFocused: Bool

    init(note: TerminalNote, store: TerminalNoteStore, inputHub: TerminalInputHub,
         isExpanded: Bool, isEditorEnlarged: Bool,
         onToggleExpand: @escaping () -> Void, onToggleEditorEnlarged: @escaping () -> Void,
         onRequestDelete: @escaping () -> Void, onExecuted: @escaping (_ ok: Bool) -> Void) {
        self.note = note
        self.store = store
        self.inputHub = inputHub
        self.isExpanded = isExpanded
        self.isEditorEnlarged = isEditorEnlarged
        self.onToggleExpand = onToggleExpand
        self.onToggleEditorEnlarged = onToggleEditorEnlarged
        self.onRequestDelete = onRequestDelete
        self.onExecuted = onExecuted
        _titleDraft = State(initialValue: note.title)
        _contentDraft = State(initialValue: note.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleBar
            if isExpanded {
                contentEditor
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isExpanded ? Color.primary.opacity(0.06) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isExpanded ? Theme.Palette.accentStroke : Color.primary.opacity(0.08))
        )
    }

    /// 标题行：箭头 + 标题组成的大热区（整条宽度可点，解决小箭头难点中）；
    /// 右侧执行 / 更多按钮独立命中，不触发行点击。
    private var titleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)

            titleView

            Spacer(minLength: 0)

            Button {
                guard let body = note.executableBody else { return }
                onExecuted(inputHub.send(body, pressReturn: true))
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(note.executableBody == nil)
            .help("发送到终端并执行")

            Menu {
                Button("删除", role: .destructive) { onRequestDelete() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("更多操作")
        }
        .contentShape(Rectangle())
        // 双击手势须先挂（优先仲裁），单击再挂：单击展开收起，双击重命名。
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { onToggleExpand() }
        .help(isExpanded ? "单击收起" : "单击展开")
    }

    /// 标题：默认展示态为纯文本（单击行切换展开，双击重命名）；重命名态为输入框。
    @ViewBuilder
    private var titleView: some View {
        if isEditingTitle {
            TextField("未命名记事", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .focused($titleFieldFocused)
                .onKeyPress(.escape) {
                    cancelRename()
                    return .handled
                }
                .onSubmit(commitRename)
                // 变更即写穿（与旧实现一致）；失焦退出编辑态。
                .onChange(of: titleDraft) { _, new in store.rename(id: note.id, title: new) }
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused, isEditingTitle {
                        isEditingTitle = false
                    }
                }
        } else {
            Text(note.displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
    }

    /// 内容编辑器：等宽字体，空内容时显示占位提示（TextEditor 无原生 placeholder）。
    /// 右上角放大按钮：放大时编辑器加高、整个面板加宽（状态在面板层）。
    private var contentEditor: some View {
        TextEditor(text: $contentDraft)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            // TextEditor 内部 NSScrollView 的旧式滚动条是一条大白竖条，彻底隐藏。
            .scrollIndicators(.hidden)
            .focused($editorFocused)
            .frame(height: isEditorEnlarged
                   ? Theme.Metrics.notepadEditorExpandedHeight
                   : Theme.Metrics.notepadEditorHeight)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(alignment: .topLeading) {
                if contentDraft.isEmpty {
                    Text("输入要执行的命令…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onToggleEditorEnlarged) {
                    Image(systemName: isEditorEnlarged
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help(isEditorEnlarged ? "恢复大小" : "放大编辑")
            }
            .onChange(of: contentDraft) { _, new in store.updateContent(id: note.id, content: new) }
            // 展开即编辑：编辑器插入（展开 / 新建记事）时直接落焦，等一拍确保已挂到窗口。
            .onAppear { DispatchQueue.main.async { editorFocused = true } }
    }

    // MARK: 重命名

    private func beginRename() {
        guard !isEditingTitle else { return }
        titleDraft = note.title
        isEditingTitle = true
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    private func commitRename() {
        guard isEditingTitle else { return }
        store.rename(id: note.id, title: titleDraft)
        isEditingTitle = false
    }

    /// 取消重命名：丢弃草稿，恢复原标题。
    private func cancelRename() {
        titleDraft = note.title
        isEditingTitle = false
    }
}
