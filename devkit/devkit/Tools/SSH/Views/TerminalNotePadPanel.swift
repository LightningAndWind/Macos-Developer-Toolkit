//
//  TerminalNotePadPanel.swift
//  devkit
//
//  终端记事本右侧面板：记事按 SSH 会话记录分类的片段库（SQLite 持久化）。
//  顶部分类切换器默认选中**当前会话的记录**，可切到其他记录（含未分类）查看其记事 ——
//  执行不受分类限制，任何记事都发往**当前**终端（跨记录复用片段正是分类浏览的意义）。
//  支持：新建（落入选中分类）/ 右键标题行重命名 / 删除（二次确认）/ 展开编辑内容。
//  手风琴式展开：同一时刻只展开一条，展开态即编辑态。
//  行交互：单击行任意处（含箭头/标题区）立即展开收起；右键标题行弹出「重命名 / 删除」菜单；
//  编辑器可放大（行内高度 + 面板整体宽度一起放大）。
//
//  ## 性能约定
//  1. 面板实现 Equatable：上层（SSHToolView）每轮 body 都会新建 `onToggleEditorEnlarged`
//     闭包，若不显式忽略，面板结构比较永远失败 → 终端侧任何重绘都会传染成面板 body 重算。
//  2. 分类候选只在子视图出现 / 记录变更通知时加载一次，且底层带数据库缓存；
//     旧实现每轮 body 都同步查一次 SQLite + localized 排序。
//  3. `visibleNotes` 每轮 body 只过滤一次，作为参数传给列表 / 底部 / 空态。
//  4. 展开不做全局 `withAnimation`：LazyVStack 整列在动画事务中重排 + 同时插入
//     NSTextView，是「粘滞感」的主要来源。只给箭头旋转留一个局部 micro 动画。
//  5. 行同样 Equatable，展开时只有展开态真正变化的行重算 body；标题 / 内容显示走
//     本地草稿，编辑写穿不广播（见 TerminalNoteStore），击键不牵动其余行。
//

import Combine
import SwiftUI

struct TerminalNotePadPanel: View, Equatable {
    let inputHub: TerminalInputHub
    /// 当前会话来源的 SSH 记录（分类归属与默认视图的依据）；nil = 临时会话 / 未选择 → 未分类。
    let currentProfileID: UUID?
    /// 编辑器放大态（由 SSHToolView 持有：放大时面板整体宽度也要加宽，状态须在其上）。
    let editorEnlarged: Bool
    var onToggleEditorEnlarged: () -> Void = {}

    /// 单例是引用类型，直接 let 持有即可；放在 @State 里反而多一层无意义的失效源。
    private let store = TerminalNoteStore.shared

    /// 正在查看的分类（SSH 记录 id）；nil = 未分类。默认跟随当前会话记录。
    @State private var selectedProfileID: UUID?
    /// 当前展开（可编辑内容）的记事；nil = 全部收起。
    @State private var expandedID: UUID?
    /// 待删除确认的记事（confirmationDialog 以此驱动）。
    @State private var pendingDeleteID: UUID?
    /// 底部提示条文案（执行成功 / 失败），几秒后自动消失。
    @State private var flash: Flash?
    @State private var flashTask: Task<Void, Never>?
    /// 分类下拉展开时抬升其所在行，让弹层盖过后续渲染的记事列表。
    @State private var categoryPickerRaised = false

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

    /// 忽略每次新建的回调闭包：它捕获的是上层 @State 的投影，功能上恒定等价。
    static func == (lhs: TerminalNotePadPanel, rhs: TerminalNotePadPanel) -> Bool {
        lhs.inputHub === rhs.inputHub
            && lhs.currentProfileID == rhs.currentProfileID
            && lhs.editorEnlarged == rhs.editorEnlarged
            // 双保险：列表组成变化时即便父级只是重新构造了本视图，也一定重算 body。
            // 击键写穿不递增 revision，因此不会影响输入性能。
            && lhs.store.revision == rhs.store.revision
    }

    var body: some View {
        let notes = store.notes(inProfile: selectedProfileID)
        let panel = VStack(alignment: .leading, spacing: 8) {
            header
            categoryPicker
            noteList(notes)
            footer(notes)
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
        return panel
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

    /// 独立子视图：候选列表由它自己持有，父面板 body 重算时不会连带查库 / 重建选项。
    /// `zIndex` 必须加在 VStack 的直接子视图上：下拉弹层要溢出这一行、盖住后面的记事列表。
    private var categoryPicker: some View {
        NoteCategoryPicker(selection: $selectedProfileID,
                           isRaised: $categoryPickerRaised,
                           maxPanelWidth: panelContentWidth)
            .zIndex(categoryPickerRaised ? 1 : 0)
    }

    /// 面板内容宽度（左右各 10pt 内边距）：分类下拉以此锚定左缘并收窄弹层宽度，
    /// 切换分类时弹层不再随触发器文字长短左右漂移。
    private var panelContentWidth: CGFloat {
        (editorEnlarged ? Theme.Metrics.notepadPanelExpandedWidth
                        : Theme.Metrics.notepadPanelWidth) - 20
    }

    // MARK: 列表

    private func noteList(_ notes: [TerminalNote]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(notes) { note in
                    TerminalNoteRow(note: note,
                                    store: store,
                                    inputHub: inputHub,
                                    isExpanded: expandedID == note.id,
                                    isEditorEnlarged: editorEnlarged,
                                    onToggleExpand: { toggleExpand(note) },
                                    onToggleEditorEnlarged: onToggleEditorEnlarged,
                                    onRequestDelete: { pendingDeleteID = note.id },
                                    onExecuted: { ok in reportExecution(ok) })
                        .equatable()
                }
            }
            .padding(.vertical, 2)
            // 右侧留余量：避免行尾按钮与自绘滚动指示条重叠。
            .padding(.trailing, 8)
        }
        .scrollIndicators(.never)
        .scrollIndicatorBar()
        .overlay {
            if notes.isEmpty {
                Text("当前分类暂无记事\n点右上角 + 新建")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: 底部

    private func footer(_ notes: [TerminalNote]) -> some View {
        HStack {
            Text(String(format: L("%@ 条"), String(notes.count)))
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
        // 展开即编辑：行内编辑器 onAppear 自动聚焦。直接赋值，不开全局动画事务。
        expandedID = note.id
    }

    private func toggleExpand(_ note: TerminalNote) {
        // 单击立即触发；不做 withAnimation —— 整列 LazyVStack 参与动画会让
        // TextEditor 的插入与布局挤在同一事务里，产生明显粘滞。
        expandedID = (expandedID == note.id) ? nil : note.id
    }

    private func confirmDelete() {
        guard let id = pendingDeleteID else { return }
        if expandedID == id { expandedID = nil }
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
            flash = nil
        }
    }

    /// 从 store 取最新标题：编辑写穿不再广播（也不改列表数组的对外快照），
    /// 用旧数组里的 note 会让「刚改名就删除」显示旧名字。
    private var pendingDeleteTitle: String {
        guard let id = pendingDeleteID else { return "未命名记事" }
        return store.note(id: id)?.displayTitle ?? "未命名记事"
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

// MARK: - 分类选择器

/// 与 Git「切换分支」同款的自绘下拉（`DropdownPicker`）：触发器显示当前分类，
/// 展开后勾选当前项、悬停高亮、点面板外收起，贴近窗口下沿自动上翻。
///
/// 弹层**左缘固定在触发器（面板内容）左缘**、宽度收在面板内：触发器宽度随分类名长短变化，
/// 若沿用右缘对齐，切分类时弹层会左右跳（短名字还会溢出面板左侧）。
///
/// 候选列表自持：只在出现与「记录增删改」通知时刷新，父面板每轮 body 不会重建选项。
private struct NoteCategoryPicker: View {
    @Binding var selection: UUID?
    /// 弹层展开时由上层抬升 zIndex，避免被排在后面的记事列表盖住。
    @Binding var isRaised: Bool
    /// 弹层宽度上限（= 记事本面板内容宽度）。
    let maxPanelWidth: CGFloat
    @State private var options: [Category] = []

    struct Category: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    var body: some View {
        DropdownPicker(
            options: dropdownOptions,
            help: "切换记事分类（点击选择 SSH 记录）",
            alignsTrailing: false,
            maxPanelWidth: maxPanelWidth,
            onPresentedChange: { isRaised = $0 }
        ) { _ in
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(currentName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .sshProfilesDidChange)) { _ in
            reload()
        }
    }

    private var currentName: String {
        guard let selection,
              let match = options.first(where: { $0.id == selection }) else { return "未分类" }
        return match.name
    }

    private var dropdownOptions: [DropdownOption] {
        var result: [DropdownOption] = [
            DropdownOption(title: "未分类", checked: selection == nil,
                           action: { selection = nil })
        ]
        result.append(contentsOf: options.map { option in
            DropdownOption(title: option.name,
                           checked: selection == option.id,
                           action: { selection = option.id })
        })
        return result
    }

    private func reload() {
        // 底层 allRequestSummaries() 带缓存，这里只是一次数组构造 + 比较。
        let fresh = SSHProfileStore.allRequestSummaries().map { Category(id: $0.id, name: $0.name) }
        if fresh != options { options = fresh }
    }
}

// MARK: - 记事行

/// 一条记事：标题行（展开箭头 + 标题 + 执行）+ 展开态的内容编辑器。
/// 行交互：单击箭头/标题区立即展开收起；右键标题行弹「重命名 / 删除」。
/// 标题/内容草稿存本地 @State，变更即写穿到 store（但不广播，见 TerminalNoteStore）。
private struct TerminalNoteRow: View, Equatable {
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
    /// 标题重命名态（右键进入；提交/取消退出）。默认态标题为纯展示 Text。
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

    /// 忽略每轮新建的四个回调闭包；只比较真正影响渲染的输入。
    static func == (lhs: TerminalNoteRow, rhs: TerminalNoteRow) -> Bool {
        lhs.note == rhs.note
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isEditorEnlarged == rhs.isEditorEnlarged
            && lhs.inputHub === rhs.inputHub
    }

    /// 用本地草稿而非 note 计算：编辑写穿不广播，note 是行创建时的快照，
    /// 用它会让「执行」按钮发出旧内容。
    private var executableBody: String? {
        let trimmed = contentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
    /// 右侧执行按钮独立命中，不触发行点击。重命名 / 删除收进右键菜单。
    private var titleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
                // 只给箭头留局部动画；不给整个列表开动画事务。
                .animation(Theme.Motion.micro, value: isExpanded)

            titleView

            Spacer(minLength: 0)

            Button {
                guard let body = executableBody else { return }
                onExecuted(inputHub.send(body, pressReturn: true))
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(executableBody == nil)
            .help("发送到终端并执行")
        }
        .contentShape(Rectangle())
        // 只挂单击：立即触发展开/收起。双击改重命名会让单击等待双击判定（约 0.3s 延迟）。
        .onTapGesture { onToggleExpand() }
        .contextMenu {
            Button("重命名") { beginRename() }
            Button("删除", role: .destructive) { onRequestDelete() }
        }
        .help(isExpanded ? "单击收起" : "单击展开")
    }

    /// 标题：默认展示态为纯文本（走本地草稿），重命名态为输入框。
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
                .onChange(of: titleDraft) { _, new in store.rename(id: note.id, title: new) }
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused, isEditingTitle {
                        isEditingTitle = false
                    }
                }
        } else {
            Text(displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
    }

    private var displayTitle: String {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名记事" : trimmed
    }

    /// 内容编辑器：等宽字体，空内容时显示占位提示（TextEditor 无原生 placeholder）。
    /// 右上角放大按钮：放大时编辑器加高、整个面板加宽（状态在面板层）。
    private var contentEditor: some View {
        TextEditor(text: $contentDraft)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .background(TextEditorScrollerHider())
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
        // 取 store 最新值：写穿不广播，note 是行创建时的快照；直接重置为 note.title 会丢字。
        titleDraft = store.note(id: note.id)?.title ?? note.title
        isEditingTitle = true
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    private func commitRename() {
        guard isEditingTitle else { return }
        store.rename(id: note.id, title: titleDraft)
        isEditingTitle = false
    }

    /// 取消重命名：标题是「变更即写穿」的，ESC 只退出编辑态，不把已落库的文字倒回去。
    private func cancelRename() {
        titleDraft = store.note(id: note.id)?.title ?? note.title
        isEditingTitle = false
    }
}

/// 彻底摘掉 TextEditor 内部 NSScrollView 的竖向滚动条：系统「始终显示滚动条」设置下，
/// legacy 滚动条是一条不透明白色轨道矩形（`.scrollIndicators(.never)` 在部分版本盖不住它）。
private struct TextEditorScrollerHider: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 缓存首次找到的 NSScrollView：本视图在编辑器每次状态变化（每个击键）都会走
    /// updateNSView，逐级向上全树搜 NSScrollView 的代价随之变成高频开销，必须只找一次。
    final class Coordinator {
        weak var scroller: NSScrollView?
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.hide(from: view, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Self.hide(from: view, coordinator: context.coordinator)
    }

    /// 背景视图与 TextEditor 的 NSScrollView 互为祖先/兄弟：缓存失效（编辑器重建）时
    /// 重新逐级向上、在每级含子树查找；命中后以「host 是其后代」校验缓存时效性。
    private static func hide(from host: NSView, coordinator: Coordinator) {
        if let cached = coordinator.scroller, host.isDescendant(of: cached) {
            // 缓存命中时只做两个 Bool 判断：无条件写 hasVerticalScroller 会让
            // NSScrollView 在每次击键都失效重排，是编辑器输入粘滞的隐藏开销。
            if cached.hasVerticalScroller || cached.verticalScroller?.isHidden == false {
                apply(to: cached)
            }
            return
        }
        var current: NSView? = host
        while let node = current {
            if let scrollView = findScrollView(in: node) {
                coordinator.scroller = scrollView
                apply(to: scrollView)
                return
            }
            current = node.superview
        }
    }

    private static func apply(to scrollView: NSScrollView) {
        scrollView.hasVerticalScroller = false
        scrollView.verticalScroller?.isHidden = true
    }

    private static func findScrollView(in root: NSView) -> NSScrollView? {
        if let scrollView = root as? NSScrollView { return scrollView }
        for subview in root.subviews {
            if let scrollView = findScrollView(in: subview) { return scrollView }
        }
        return nil
    }
}
