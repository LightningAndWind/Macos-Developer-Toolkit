//
//  JSONEditorSupport.swift
//  devkit
//
//  M3 JSON 工具编辑器的基础设施：语法高亮器、深浅色自适应调色板、行号标尺视图。
//  与 Theme.Palette 中的同名着色保持视觉一致（此处为 AppKit NSColor 版本）。
//

import AppKit

/// 编辑器调色板：用动态 NSColor 保证浅/深色下均清晰。
enum JSONEditorPalette {
    static let plain = NSColor.textColor
    static let numberLabel = NSColor.tertiaryLabelColor
    static let rulerBackground = NSColor.clear

    static let key = adaptive(light: rgb(0.11, 0.34, 0.72), dark: rgb(0.45, 0.68, 1.0))
    static let string = adaptive(light: rgb(0.72, 0.18, 0.20), dark: rgb(1.00, 0.60, 0.55))
    static let number = adaptive(light: rgb(0.13, 0.50, 0.30), dark: rgb(0.50, 0.85, 0.60))
    static let literal = adaptive(light: rgb(0.55, 0.26, 0.66), dark: rgb(0.80, 0.55, 0.95))
    static let punctuation = adaptive(light: NSColor(white: 0, alpha: 0.55), dark: NSColor(white: 1, alpha: 0.55))
    static let matchBackground = adaptive(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.18))

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// 单遍正则式 JSON 语法着色：字符串整段吞掉，避免误着色其内部数字/关键字。
enum JSONSyntaxHighlighter {
    /// 组合模式：字符串 | 字面量 | 数字 | 标点。字符串分支置首以优先消费。
    private static let tokenRegex = try? NSRegularExpression(
        pattern: "\"(?:\\\\.|[^\"\\\\])*\"|\\btrue\\b|\\bfalse\\b|\\bnull\\b|-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?|[{}\\[\\],:]"
    )

    /// 括号配对表（用于匹配高亮）。
    static func bracketPair(for char: String) -> (open: String, close: String)? {
        switch char {
        case "{", "}": return ("{", "}")
        case "[", "]": return ("[", "]")
        default: return nil
        }
    }

    static func highlight(_ storage: NSTextStorage, font: NSFont) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: JSONEditorPalette.plain], range: full)
        if let regex = tokenRegex {
            regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                guard let match, match.range.length > 0 else { return }
                let color = color(for: ns, match: match)
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        storage.endEditing()
    }

    private static func color(for ns: NSString, match: NSTextCheckingResult) -> NSColor {
        let token = ns.substring(with: match.range)
        switch token.first {
        case "\"":
            return isKey(ns, after: match.range) ? JSONEditorPalette.key : JSONEditorPalette.string
        case "{", "}", "[", "]", ",", ":":
            return JSONEditorPalette.punctuation
        case "t", "f", "n":
            return JSONEditorPalette.literal
        default:
            return JSONEditorPalette.number
        }
    }

    /// 字符串 token 之后跳过空白若紧跟 ':'，则为对象键。
    private static func isKey(_ ns: NSString, after range: NSRange) -> Bool {
        var i = NSMaxRange(range)
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1; continue }
            return c == 0x3A // ':'
        }
        return false
    }
}

/// 左侧行号标尺：随文本滚动同步绘制每行行号。
final class LineNumberRulerView: NSRulerView {
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Theme.Metrics.jsonLineNumberGutterWidth
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 依据总行数加宽 gutter，避免大文档行号被截断。
    func updateThickness(lineCount: Int) {
        let digits = max(2, String(lineCount).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: font]).width + 16
        let needed = max(Theme.Metrics.jsonLineNumberGutterWidth, width)
        if abs(needed - ruleThickness) > 0.5 { ruleThickness = needed }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        JSONEditorPalette.rulerBackground.setFill()
        rect.fill()

        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let content = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: JSONEditorPalette.numberLabel]
        // 文本视图原点映射到标尺坐标，天然跟随滚动。
        let relativePoint = convert(NSPoint.zero, from: textView)
        let inset = textView.textContainerInset.height

        func drawLabel(_ number: Int, at documentY: CGFloat) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = documentY + relativePoint.y
            guard y + size.height >= rect.minY, y <= rect.maxY else { return }
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }

        if content.length == 0 {
            drawLabel(1, at: inset)
            return
        }

        var lineNumber = 1
        content.enumerateSubstrings(in: NSRange(location: 0, length: content.length),
                                    options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            drawLabel(lineNumber, at: lineRect.minY + inset)
            lineNumber += 1
        }
    }
}
