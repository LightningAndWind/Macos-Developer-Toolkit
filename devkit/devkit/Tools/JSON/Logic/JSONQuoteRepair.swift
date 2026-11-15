//
//  JSONQuoteRepair.swift
//  devkit
//
//  M3 JSON 工具：单引号 JSON 修复。粘贴 {'aaa':'ccc'} 这类误用单引号的文本时，
//  自动把键/值的单引号改写为双引号；字符串内容里的单引号（撇号）原样保留。
//  双重保险：原文已是合法 JSON 不动；改写结果无法通过完整解析也不采用，绝不改坏内容。
//

import Foundation

/// 单引号 → 双引号修复器（仅在粘贴路径自动触发，见 JSONTextView）。
enum JSONQuoteRepair {
    /// 剪贴板文本含可修复的单引号错误时返回改写结果；否则返回 nil（保持原样粘贴）。
    /// - 原文本身是合法 JSON（如双引号串里的撇号）→ 无需修复，返回 nil；
    /// - 改写后仍无法完整解析（如纯文本、含尾逗号等其他错误）→ 返回 nil，不强行动刀。
    static func repairIfInvalid(_ raw: String) -> String? {
        guard raw.contains("'") else { return nil }
        if case .success = JSONParser.parse(raw) { return nil }
        let fixed = rewriteSingleQuotedStrings(raw)
        guard fixed != raw, case .success = JSONParser.parse(fixed) else { return nil }
        return fixed
    }

    // MARK: - 改写

    /// 字符级状态机：字符串外的 `'` 一律视作字符串边界（开/闭引号）改写为 `"`；
    /// 单引号串内部的 `'` 用「后随字符」启发式区分闭合引号与内容撇号：
    /// `'` 之后（允许隔空白）紧跟 `,` `}` `]` `:` 或到结尾 → 闭合；否则是内容，如 don't。
    private static func rewriteSingleQuotedStrings(_ raw: String) -> String {
        let chars = Array(raw)
        var out = String()
        out.reserveCapacity(raw.count)

        var inDouble = false // 双引号字符串内：内容原样抄写（其中出现的单引号是内容，不参与改写）
        var inSingle = false // 单引号字符串内：整体改写为双引号字符串
        var escaped = false  // 字符串内上一字符是反斜杠（转义延迟到下一字符再落笔）

        var i = 0
        while i < chars.count {
            let ch = chars[i]

            if inDouble {
                out.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inDouble = false
                }
            } else if inSingle {
                if escaped {
                    escaped = false
                    // \' 是字面撇号：双引号串里无需转义；\" 保持转义写法；其余转义序列原样保留。
                    switch ch {
                    case "'": out.append("'")
                    case "\"": out.append("\\\"")
                    default:
                        out.append("\\")
                        out.append(ch)
                    }
                } else {
                    switch ch {
                    case "'":
                        if isClosingAhead(chars, after: i) {
                            out.append("\"")
                            inSingle = false
                        } else {
                            out.append(ch) // 内容撇号（如 don't），原样保留
                        }
                    case "\\":
                        escaped = true
                    case "\"":
                        out.append("\\\"") // 内容里的双引号改写后必须转义
                    default:
                        out.append(ch)
                    }
                }
            } else {
                switch ch {
                case "\"":
                    inDouble = true
                    out.append(ch)
                case "'":
                    inSingle = true
                    out.append("\"") // 字符串外的单引号视作开引号 → 改为 "
                default:
                    out.append(ch)
                }
            }
            i += 1
        }
        return out
    }

    /// 单引号串内位置 index 的 `'` 之后（允许隔着空白/换行）紧跟结构字符 `,` `}` `]` `:` 或到结尾
    /// → 视作闭合引号；后随普通字符则视作内容撇号。
    private static func isClosingAhead(_ chars: [Character], after index: Int) -> Bool {
        var j = index + 1
        while j < chars.count, chars[j] == " " || chars[j] == "\t"
                || chars[j] == "\n" || chars[j] == "\r" { j += 1 }
        guard j < chars.count else { return true } // 到结尾：尽量闭合，能否解析交给最终校验兜底
        switch chars[j] {
        case ",", "}", "]", ":": return true
        default: return false
        }
    }
}
