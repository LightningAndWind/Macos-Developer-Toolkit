//
//  JSONFormatting.swift
//  devkit
//
//  M3 JSON 工具：把 JSONValue 序列化回文本。pretty 支持 2/4 空格或 Tab 缩进，minify 去空白。
//

import Foundation

/// 缩进风格；rawValue 作为会话持久化键，勿随意变更。
enum JSONIndent: String, CaseIterable, Codable {
    case spaces2
    case spaces4
    case tab

    /// 单层缩进字符串。
    var unit: String {
        switch self {
        case .spaces2: return "  "
        case .spaces4: return "    "
        case .tab:     return "\t"
        }
    }

    var label: String {
        switch self {
        case .spaces2: return "2 空格"
        case .spaces4: return "4 空格"
        case .tab:     return "Tab"
        }
    }
}

/// JSONValue → 文本序列化。
enum JSONSerializer {
    /// 带层级缩进的美化输出；空容器收成 `{}` / `[]`。
    static func pretty(_ value: JSONValue, indent: JSONIndent) -> String {
        var out = ""
        write(value, level: 0, indent: indent, into: &out)
        return out
    }

    /// 压缩：去除所有结构空白。
    static func minify(_ value: JSONValue) -> String {
        var out = ""
        write(value, level: 0, indent: nil, into: &out)
        return out
    }

    // MARK: - 递归写入

    /// `indent == nil` 表示压缩模式（不加换行与缩进）。
    private static func write(_ value: JSONValue, level: Int, indent: JSONIndent?, into out: inout String) {
        switch value {
        case .null:  out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): out += encodeString(s)
        case .array(let values): writeContainer(open: "[", close: "]", elements: values.map { ($0, nil) }, level: level, indent: indent, into: &out)
        case .object(let members):
            writeContainer(open: "{", close: "}",
                           elements: members.map { ($0.value, JSONValue.string($0.key)) },
                           level: level, indent: indent, into: &out)
        }
    }

    /// 统一写数组/对象：`keyValue` 携带键时（对象）写 `"键": 值`，仅值时（数组）写值。
    private static func writeContainer(open: String, close: String, elements: [(JSONValue, JSONValue?)],
                                       level: Int, indent: JSONIndent?, into out: inout String) {
        out += open
        guard !elements.isEmpty else { out += close; return }

        let pad = indent.map { String(repeating: $0.unit, count: level + 1) } ?? ""
        let closingPad = indent.map { String(repeating: $0.unit, count: level) } ?? ""
        let newline = indent == nil ? "" : "\n"

        for (position, element) in elements.enumerated() {
            if position > 0 { out += "," }
            out += newline + pad
            if let key = element.1 {
                write(key, level: level + 1, indent: indent, into: &out) // 键（string）
                out += ":"
                if indent != nil { out += " " }
                write(element.0, level: level + 1, indent: indent, into: &out) // 值
            } else {
                write(element.0, level: level + 1, indent: indent, into: &out)
            }
        }
        out += newline + closingPad + close
    }

    // MARK: - 字符串编码

    /// 生成带引号并转义的 JSON 字符串字面量。
    static func encodeString(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
