//
//  JSONCodeTextView.swift
//  devkit
//
//  M3 JSON 工具：文本编辑器。基于 NSViewRepresentable 封装 NSScrollView + NSTextView，
//  提供语法高亮、行号 gutter、括号自动配对与匹配高亮、回车自动缩进。文本为唯一数据源，
//  编辑回写 tool.text，外部变更（格式化/压缩/排序）经 updateNSView 推回文本视图。
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
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.indentUnit = tool.indent.unit
        textView.string = tool.text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
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
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        weak var tool: JSONTool?

        private var isSyncing = false

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
            highlightMatchingBracket()
        }

        // MARK: 高亮

        /// 重跑语法着色；随后重建括号匹配底色。
        func rehighlight() {
            guard let storage = textView?.textStorage else { return }
            JSONSyntaxHighlighter.highlight(storage, font: Self.baseFont)
            highlightMatchingBracket()
        }

        /// 括号匹配：光标紧邻 `{}[]` 时，给配对括号加淡背景。
        private func highlightMatchingBracket() {
            guard let textView, let storage = textView.textStorage else { return }
            let ns = storage.string as NSString
            let full = NSRange(location: 0, length: ns.length)

            // 清除上一次的匹配底色。
            storage.removeAttribute(.backgroundColor, range: full)

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

/// 处理括号自动配对、引号/括号跳过、回车自动缩进的 NSTextView。
final class JSONTextView: NSTextView {
    /// 单层缩进字符串，随 tool.indent 更新。
    var indentUnit: String = "  "

    private let openPairs: [String: String] = ["{": "}", "[": "]", "\"": "\""]
    private let closers: Set<String> = ["}", "]", "\""]

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
