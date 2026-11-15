//
//  JSONCodeTextView.swift
//  devkit
//
//  M3 JSON 工具：文本编辑器。基于 NSViewRepresentable 封装 NSScrollView + NSTextView，
//  提供语法高亮、行号 gutter、括号自动配对与匹配高亮、回车自动缩进，超长行软换行显示。
//  粘贴时自动把 {'a':'b'} 这类单引号 JSON 修复为双引号（内容里的单引号不动）。
//  文本为唯一数据源，编辑回写 tool.text，外部变更（格式化/压缩/排序）经 updateNSView 推回文本视图。
//  关键字搜索（⌘F）：命中淡黄底色，当前命中深橙底 + 白字并选中定位，状态在 JSONTool，高亮由 Coordinator 统一重建。
//

import AppKit
import SwiftUI

struct JSONCodeTextView: NSViewRepresentable {
    @Bindable var tool: JSONTool
    /// 当前标签是否可见。不可见时真隐藏底层 NSTextView 并交出第一响应者，
    /// 避免其 I 型光标热区与闪烁插入点叠加到其他标签之上。
    var isActive: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(tool: tool)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = JSONTextView()
        textView.delegate = context.coordinator
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = .textColor
        textView.font = Coordinator.baseFont
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        // 软换行：容器宽度跟随视图宽度，超长行（如超长字符串值）自动折行显示，
        // 不再撑出横向滚动。折行只影响显示，文本本身不变。
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.indentUnit = tool.indent.unit
        textView.searchTool = tool
        textView.string = tool.text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let ruler = LineNumberRulerView(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.rehighlight()
        context.coordinator.installSelectionObserver()
        // 视图重建（如标签重挂载）时若搜索已在进行，补敷命中底色并定位当前命中。
        context.coordinator.applySearchState()

        scroll.isHidden = !isActive
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView as? JSONTextView else { return }
        nsView.isHidden = !isActive
        // 标签切走：交出第一响应者，消除残留的插入点/选区绘制。
        if !isActive {
            context.coordinator.resignFirstResponderIfNeeded()
            return
        }
        textView.indentUnit = tool.indent.unit
        textView.searchTool = tool
        // 外部（格式化/压缩/排序/会话恢复）改动：仅在文本不同步时整体替换，避免打断正在输入。
        if textView.string != tool.text {
            let selected = textView.selectedRange()
            textView.string = tool.text
            let length = textView.textStorage?.length ?? 0
            let location = min(selected.location, length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            context.coordinator.rehighlight()
        }
        context.coordinator.refreshRuler()
        // 搜索状态同步：读取 @Observable 属性即注册依赖，
        // 搜索栏开关 / 关键字 / 当前命中序号的任何变化都会驱动本视图重渲染并走到这里。
        context.coordinator.applySearchState()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        weak var tool: JSONTool?

        private var isSyncing = false

        // MARK: 搜索状态缓存
        // 命中区间按「文本 + 关键字」缓存，未变化则复用；pendingSearchJump 表示
        // 需要把当前命中重新选中并滚动定位（打开搜索栏 / 关键字变化时置位）。
        private var searchLastText: String?
        private var searchLastQuery: String?
        private var searchRanges: [NSRange] = []
        private var lastSearchVisible = false
        private var lastAppliedSearchIndex = -1
        private var pendingSearchJump = false
        /// 上一次敷了「当前命中」白字前景的区间：重画前先按语法着色还原该处，
        /// 否则命中挪走/搜索关闭后会残留白字。
        private var paintedCurrentRange: NSRange?

        init(tool: JSONTool) { self.tool = tool }

        func textDidChange(_ notification: Notification) {
            guard !isSyncing else { return }
            rehighlight()
            refreshRuler()
            // 回写模型；SwiftUI 会据此重解析并驱动状态栏/树视图。
            if let text = textView?.string, text != tool?.text {
                tool?.text = text
            }
        }

        func installSelectionObserver() {
            guard let textView else { return }
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(selectionChanged),
                                                   name: NSTextView.didChangeSelectionNotification,
                                                   object: textView)
        }

        @objc private func selectionChanged() {
            refreshBackgroundHighlights()
        }

        // MARK: 搜索

        /// 模型侧搜索状态 → 文本视图的同步入口（updateNSView / makeNSView 末尾调用）。
        func applySearchState() {
            guard let textView, let tool else { return }
            // 鼠标悬停搜索栏期间让文本视图让出 I 型光标（onHover 写标志位会驱动本方法重跑）。
            (textView as? JSONTextView)?.suspendCursorTracking(tool.isSearchVisible && tool.isPointerOverFindBar)
            _ = currentSearchRanges(tool: tool) // 重算命中并回写总数
            refreshBackgroundHighlights()

            if tool.isSearchVisible != lastSearchVisible {
                let wasVisible = lastSearchVisible
                lastSearchVisible = tool.isSearchVisible
                if wasVisible {
                    // 关闭搜索栏：焦点交回编辑器（等一拍，避免在视图更新事务内改第一响应者）。
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let textView = self.textView,
                              let window = textView.window,
                              window.firstResponder !== textView else { return }
                        window.makeFirstResponder(textView)
                    }
                } else {
                    pendingSearchJump = true
                }
            }

            // 定位当前命中：序号变化（上一/下一个）或打开搜索栏 / 换关键字时跳转。
            if tool.isSearchVisible,
               searchRanges.indices.contains(tool.searchMatchIndex),
               (tool.searchMatchIndex != lastAppliedSearchIndex || pendingSearchJump) {
                pendingSearchJump = false
                lastAppliedSearchIndex = tool.searchMatchIndex
                let range = searchRanges[tool.searchMatchIndex]
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
            }
        }

        /// 命中区间缓存：文本或关键字自上次计算后变化才重算，并回写命中总数、
        /// 在换关键字时把当前命中归零（文本仅编辑则尽量保留原序号）。
        private func currentSearchRanges(tool: JSONTool) -> [NSRange] {
            let text = textView?.string ?? ""
            if text == searchLastText, tool.searchQuery == searchLastQuery { return searchRanges }
            let queryChanged = tool.searchQuery != searchLastQuery
            searchLastText = text
            searchLastQuery = tool.searchQuery
            searchRanges = JSONSyntaxHighlighter.matchRanges(of: tool.searchQuery, in: text)
            if tool.searchMatchCount != searchRanges.count {
                tool.searchMatchCount = searchRanges.count
            }
            if queryChanged || tool.searchMatchIndex >= max(searchRanges.count, 1) {
                tool.searchMatchIndex = 0
            }
            if queryChanged {
                pendingSearchJump = true
            } else {
                // 纯文本编辑/外部替换引起的重算：只更新高亮，不挪动定位（避免打断输入），
                // 静默同步已应用序号，防止随后的 applySearchState 误判为「序号变化」而跳转。
                lastAppliedSearchIndex = tool.searchMatchIndex
            }
            return searchRanges
        }

        // MARK: 高亮

        /// 重跑语法着色；随后重建全部背景高亮。
        func rehighlight() {
            guard let storage = textView?.textStorage else { return }
            JSONSyntaxHighlighter.highlight(storage, font: Self.baseFont)
            refreshBackgroundHighlights()
        }

        /// 重建全部背景色：清全量 → 还原上次当前命中的白字 → 括号匹配 → 搜索命中。
        /// `.backgroundColor` 统一由本方法管理：语法着色的 setAttributes 会整体重置属性字典，
        /// 故编辑（textDidChange）、选区变化、外部文本替换三条路径都汇到这里收尾，
        /// 搜索底色因此总能敷在最后一层、不被清除路径漏掉。
        private func refreshBackgroundHighlights() {
            guard let textView, let storage = textView.textStorage else { return }
            let ns = storage.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            storage.removeAttribute(.backgroundColor, range: full)
            if let prev = paintedCurrentRange,
               prev.length > 0, prev.location + prev.length <= ns.length {
                JSONSyntaxHighlighter.recolor(storage, range: prev)
            }
            paintedCurrentRange = nil
            highlightMatchingBracket()
            paintSearchMatches(tool: tool, storage: storage)
        }

        /// 给全部命中敷底色（仅当搜索栏开启且关键字非空）；
        /// 当前命中另敷近实心深橙底 + 白字，与普通命中的淡黄一眼拉开。
        private func paintSearchMatches(tool: JSONTool?, storage: NSTextStorage) {
            guard let tool, tool.isSearchVisible, !tool.searchQuery.isEmpty else { return }
            let ranges = currentSearchRanges(tool: tool)
            for range in ranges {
                storage.addAttribute(.backgroundColor,
                                     value: JSONEditorPalette.searchBackground,
                                     range: range)
            }
            if ranges.indices.contains(tool.searchMatchIndex) {
                let range = ranges[tool.searchMatchIndex]
                storage.addAttribute(.backgroundColor,
                                     value: JSONEditorPalette.searchCurrentBackground,
                                     range: range)
                storage.addAttribute(.foregroundColor,
                                     value: JSONEditorPalette.searchCurrentForeground,
                                     range: range)
                paintedCurrentRange = range
            }
        }

        /// 括号匹配：光标紧邻 `{}[]` 时，给配对括号加淡背景。
        /// 背景清除由 `refreshBackgroundHighlights()` 统一负责，这里只增不删。
        private func highlightMatchingBracket() {
            guard let textView, let storage = textView.textStorage else { return }
            let ns = storage.string as NSString

            let sel = textView.selectedRange()
            guard sel.length == 0, sel.location > 0 || (sel.location < ns.length) else { return }

            let candidates = [sel.location - 1, sel.location]
            for idx in candidates {
                guard idx >= 0, idx < ns.length else { continue }
                let ch = ns.substring(with: NSRange(location: idx, length: 1))
                guard let (open, close) = JSONSyntaxHighlighter.bracketPair(for: ch) else { continue }
                let step = ch == open ? 1 : -1
                var depth = 0
                var i = idx
                while i >= 0, i < ns.length {
                    let c = ns.substring(with: NSRange(location: i, length: 1))
                    if c == open { depth += 1 }
                    else if c == close { depth -= 1 }
                    if depth == 0, i != idx {
                        storage.addAttribute(.backgroundColor,
                                             value: JSONEditorPalette.matchBackground,
                                             range: NSRange(location: idx, length: 1))
                        storage.addAttribute(.backgroundColor,
                                             value: JSONEditorPalette.matchBackground,
                                             range: NSRange(location: i, length: 1))
                        break
                    }
                    i += step
                }
                if JSONSyntaxHighlighter.bracketPair(for: ns.substring(with: NSRange(location: idx, length: 1))) != nil {
                    break
                }
            }
        }

        func refreshRuler() {
            guard let textView, let ruler else { return }
            let lineCount = textView.string.components(separatedBy: .newlines).count
            ruler.updateThickness(lineCount: lineCount)
            ruler.needsDisplay = true
        }

        /// 若本编辑器是当前窗口第一响应者，交出响应者身份，消除隐藏后的插入点/选区残留。
        func resignFirstResponderIfNeeded() {
            guard let textView, let window = textView.window,
                  window.firstResponder === textView else { return }
            window.makeFirstResponder(nil)
        }
    }
}

// MARK: - 文本视图子类（自动配对 + 自动缩进）

/// 处理括号自动配对、引号/括号跳过、回车自动缩进与查找快捷键的 NSTextView。
final class JSONTextView: NSTextView {
    /// 单层缩进字符串，随 tool.indent 更新。
    var indentUnit: String = "  "

    /// 所属工具模型：处理 ⌘F（唤出搜索栏）/ ⌘G（下一个）/ ⇧⌘G（上一个）时回调。
    weak var searchTool: JSONTool?

    private let openPairs: [String: String] = ["{": "}", "[": "]", "\"": "\""]
    private let closers: Set<String> = ["}", "]", "\""]

    /// 查找快捷键：⌘F 唤出搜索栏、⌘G / ⇧⌘G 逐个命中导航。
    /// 视图未聚焦时也会经窗口的 performKeyEquivalent 层级遍历走到这里，编辑区内随时可用。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if let searchTool, key == "f", mods == [.command] {
            searchTool.openSearch()
            return true
        }
        if let searchTool, key == "g", mods == [.command] || mods == [.command, .shift] {
            if mods.contains(.shift) {
                searchTool.previousSearchMatch()
            } else {
                searchTool.nextSearchMatch()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// 鼠标悬停在悬浮搜索栏上时不再抢设 I 型光标：NSTextView 的光标跟踪区
    /// 覆盖整个文本区域且不理会上层浮层，每次鼠标移动都会盖掉搜索栏按钮的手型光标，
    /// 这里显式让位，交给浮层自己的箭头/手型光标（输入框内的 I 型由 NSTextField 自行设置）。
    override func cursorUpdate(with event: NSEvent) {
        guard searchTool?.isPointerOverFindBar != true else { return }
        super.cursorUpdate(with: event)
    }

    // MARK: 悬浮搜索栏期间的光标让位

    /// 为 true 时已摘除自身光标跟踪区，不再参与光标设置。
    private var isCursorTrackingSuspended = false
    /// 被摘除的跟踪区，退出悬浮态时按原样恢复。
    private var suspendedCursorAreas: [NSTrackingArea] = []

    /// 悬浮搜索栏显示期间摘除自身的光标跟踪区：NSTextView 内部设置 I 型光标
    /// 不走单一入口（cursorUpdate / 光标矩形等多条路径），逐条抑制不可靠，
    /// 直接摘掉跟踪区最彻底；离开浮层或关闭搜索栏时原样恢复。
    func suspendCursorTracking(_ suspended: Bool) {
        guard suspended != isCursorTrackingSuspended else { return }
        isCursorTrackingSuspended = suspended
        if suspended {
            suspendedCursorAreas = trackingAreas.filter { $0.options.contains(.cursorUpdate) }
            suspendedCursorAreas.forEach(removeTrackingArea)
        } else {
            // 布局期间 NSTextView 可能已自行重建部分跟踪区，避免同一实例被重复添加。
            for area in suspendedCursorAreas where !trackingAreas.contains(area) {
                addTrackingArea(area)
            }
            suspendedCursorAreas = []
            window?.invalidateCursorRects(for: self)
        }
    }

    /// 摘除期间布局系统重建的跟踪区也要摘掉，防止 I 型光标从重建的跟踪区里回来。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard isCursorTrackingSuspended else { return }
        for area in trackingAreas where area.options.contains(.cursorUpdate) {
            removeTrackingArea(area)
        }
    }

    /// 光标矩形路径同样让位：悬浮期间不注册 I 型光标矩形。
    override func resetCursorRects() {
        guard !isCursorTrackingSuspended else { return }
        super.resetCursorRects()
    }

    override func insertText(_ insertString: Any) {
        guard let string = insertString as? String else {
            super.insertText(insertString)
            return
        }

        // 单字符：自动配对 / 跳过闭合。
        if string.count == 1 {
            // 已选中文本 → 用配对符号包裹。
            if let open = openPairs[string], selectedRange().length > 0 {
                let inner = (textStorage?.attributedSubstring(from: selectedRange()).string) ?? ""
                super.insertText(open + inner + open)
                return
            }
            // 光标处已是闭合符号且无选区 → 跳过而非重复插入。
            if closers.contains(string), selectedRange().length == 0, charAtCursor() == string {
                setSelectedRange(NSRange(location: selectedRange().location + 1, length: 0))
                return
            }
            if let close = openPairs[string] {
                super.insertText(string + close)
                let pos = selectedRange().location - close.count
                setSelectedRange(NSRange(location: max(0, pos), length: 0))
                return
            }
        }
        super.insertText(string)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            autoInsertNewlineWithIndent()
            return
        }
        if selector == #selector(deleteBackward(_:)), deletePairedIfEmpty() {
            return
        }
        super.doCommand(by: selector)
    }

    // MARK: 粘贴自动修复

    /// ⌘V：剪贴板是单引号 JSON（如 {'aaa':'ccc'}）时自动改写为双引号后插入，
    /// 其余情况走系统粘贴。修复规则见 JSONQuoteRepair。
    override func paste(_ sender: Any?) {
        if let repaired = repairedPasteText() {
            insertText(repaired, replacementRange: selectedRange())
        } else {
            super.paste(sender)
        }
    }

    /// 「粘贴并匹配样式」（⌘⌥⇧V）同样经过修复。
    override func pasteAsPlainText(_ sender: Any?) {
        if let repaired = repairedPasteText() {
            insertText(repaired, replacementRange: selectedRange())
        } else {
            super.pasteAsPlainText(sender)
        }
    }

    /// 剪贴板文本若为可修复的单引号 JSON，返回改写结果；否则 nil（走系统粘贴）。
    private func repairedPasteText() -> String? {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        return JSONQuoteRepair.repairIfInvalid(raw)
    }

    private func autoInsertNewlineWithIndent() {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let lineText = ns.substring(with: lineRange)
        let leading = lineText.prefix(while: { $0 == " " || $0 == "\t" })
        // 光标前最后一个非空白字符决定是否需要多缩进一级。
        let before = ns.substring(to: sel.location).reversed().drop(while: { $0 == " " || $0 == "\t" })
        let opener = before.first.map(String.init)
        let extra = (opener == "{" || opener == "[") ? indentUnit : ""
        super.insertText("\n" + String(leading) + extra)
    }

    /// 光标位于 "{}" / "[]" 空对之间退格时，一并删除右半。
    private func deletePairedIfEmpty() -> Bool {
        guard selectedRange().length == 0, let storage = textStorage else { return false }
        let ns = storage.string as NSString
        let loc = selectedRange().location
        guard loc > 0, loc < ns.length else { return false }
        let prev = ns.substring(with: NSRange(location: loc - 1, length: 1))
        let next = ns.substring(with: NSRange(location: loc, length: 1))
        guard openPairs[prev] == next else { return false }
        super.shouldChangeText(in: NSRange(location: loc - 1, length: 2), replacementString: "")
        super.replaceCharacters(in: NSRange(location: loc - 1, length: 2), with: "")
        return true
    }

    private func charAtCursor() -> String? {
        guard let storage = textStorage else { return nil }
        let ns = storage.string as NSString
        let loc = selectedRange().location
        guard loc >= 0, loc < ns.length else { return nil }
        return ns.substring(with: NSRange(location: loc, length: 1))
    }
}
