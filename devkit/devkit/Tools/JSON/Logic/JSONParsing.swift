//
//  JSONParsing.swift
//  devkit
//
//  M3 JSON 工具：手写递归下降解析器。相比 JSONSerialization 能给出精确的行列号与
//  常见错误修复提示（尾逗号、单引号、注释、括号不匹配等），并保留键插入顺序与数字原样。
//

import Foundation

/// JSON 解析错误：带字符偏移换算出的 1-based 行列，供状态栏与编辑器定位。
struct JSONError: Error, Equatable {
    var message: String
    var hint: String?
    var offset: Int
    var line: Int
    var column: Int

    /// 由源文本与字符偏移构造，扫描偏移前的换行数得到行列。
    init(message: String, hint: String? = nil, offset: Int, source: [Character]) {
        self.message = message
        self.hint = hint
        let clamped = max(0, min(offset, source.count))
        var line = 1
        var column = 1
        var i = 0
        while i < clamped {
            if source[i] == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
            i += 1
        }
        self.offset = clamped
        self.line = line
        self.column = column
    }

    /// "第 X 行 第 Y 列：<message>"，可选追加提示。
    var displayText: String {
        var text = "第 \(line) 行 第 \(column) 列：\(message)"
        if let hint { text += "（\(hint)）" }
        return text
    }
}

/// JSON 文档解析入口。
enum JSONParser {
    static func parse(_ text: String) -> Result<JSONValue, JSONError> {
        let chars = Array(text)
        var parser = JSONValueScanner(chars: chars)
        do {
            let value = try parser.parseDocument()
            return .success(value)
        } catch let error as JSONError {
            return .failure(error)
        } catch {
            return .failure(JSONError(message: "解析失败", hint: nil, offset: chars.count, source: chars))
        }
    }
}

/// 单遍扫描的状态机；下标即字符（grapheme）偏移，与 JSONError 行列换算一致。
private struct JSONValueScanner {
    let chars: [Character]
    var index: Int = 0

    init(chars: [Character]) { self.chars = chars }

    // MARK: - 顶层

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        if isAtEnd { throw error("文档内容为空", hint: "请输入合法的 JSON") }
        let value = try parseValue()
        skipWhitespace()
        if !isAtEnd {
            throw error("存在多余的字符", hint: "JSON 只能有一个根值，检查是否漏了括号或逗号")
        }
        return value
    }

    // MARK: - 值分派

    mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard let ch = peek else { throw error("值缺失", hint: "到达文档末尾但未找到值") }
        switch ch {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t": try expectLiteral("true");  return .bool(true)
        case "f": try expectLiteral("false"); return .bool(false)
        case "n": try expectLiteral("null");  return .null
        case "-", "0"..."9": return try parseNumber()
        case "'": throw error("字符串必须使用双引号", hint: "把 '\(ch)' 改成 \"…\"")
        case "/": throw error("不支持注释", hint: "标准 JSON 不允许 // 或 /* */ 注释，请删除")
        default: throw error("意外的字符 '\(ch)'", hint: "此处应是一个值")
        }
    }

    // MARK: - 对象

    mutating func parseObject() throws -> JSONValue {
        consume() // '{'
        var members: [JSONMember] = []
        skipWhitespace()
        if peek == "}" { consume(); return .object(members) }

        while true {
            skipWhitespace()
            guard peek == "\"" else {
                if let p = peek, p == "}" {
                    throw error("对象存在尾随逗号", hint: "删除最后一个成员后的逗号")
                }
                throw error("对象键名必须是字符串", hint: "键名需用 \"…\" 包裹")
            }
            let key = try parseString()
            skipWhitespace()
            guard peek == ":" else { throw error("键名后缺少冒号 ':'", hint: "写成 \"键\": 值") }
            consume()
            let value = try parseValue()
            members.append(JSONMember(key: key, value: value))

            skipWhitespace()
            switch peek {
            case ",":
                consume()
                skipWhitespace()
                if peek == "}" {
                    throw error("对象存在尾随逗号", hint: "删除最后一个成员后的逗号")
                }
            case "}":
                consume()
                return .object(members)
            default:
                throw error("对象成员后缺少逗号或右花括号", hint: "检查 ',' 或 '}' 是否遗漏")
            }
        }
    }

    // MARK: - 数组

    mutating func parseArray() throws -> JSONValue {
        consume() // '['
        var values: [JSONValue] = []
        skipWhitespace()
        if peek == "]" { consume(); return .array(values) }

        while true {
            let value = try parseValue()
            values.append(value)
            skipWhitespace()
            switch peek {
            case ",":
                consume()
                skipWhitespace()
                if peek == "]" {
                    throw error("数组存在尾随逗号", hint: "删除最后一个元素后的逗号")
                }
            case "]":
                consume()
                return .array(values)
            default:
                throw error("数组元素后缺少逗号或右方括号", hint: "检查 ',' 或 ']' 是否遗漏")
            }
        }
    }

    // MARK: - 字符串

    mutating func parseString() throws -> String {
        guard peek == "\"" else { throw error("字符串缺少起始双引号") }
        consume()
        var result = ""
        while true {
            guard let ch = peek else { throw error("字符串未闭合", hint: "缺少结束的 \"") }
            switch ch {
            case "\"":
                consume()
                return result
            case "\\":
                consume()
                guard let esc = peek else { throw error("转义字符后缺少内容") }
                consume()
                switch esc {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/":  result.append("/")
                case "b":  result.append("\u{08}")
                case "f":  result.append("\u{0C}")
                case "n":  result.append("\n")
                case "r":  result.append("\r")
                case "t":  result.append("\t")
                case "u":  result.append(try parseUnicodeEscape())
                default: throw error("非法转义字符 '\\\(esc)'")
                }
            case "\n":
                throw error("字符串内出现裸换行", hint: "换行应转义为 \\n 或用引号包裹整段")
            default:
                result.append(ch)
                consume()
            }
        }
    }

    /// 解析 \uXXXX；处理 UTF-16 代理对。
    mutating func parseUnicodeEscape() throws -> Character {
        let code = try parseHex4()
        if (0xD800...0xDBFF).contains(code), peek == "\\", index + 1 < chars.count, chars[index + 1] == "u" {
            consume(); consume() // '\' 'u'
            let low = try parseHex4()
            if (0xDC00...0xDFFF).contains(low) {
                let scalarValue = UInt32(0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00))
                if let unicode = Unicode.Scalar(scalarValue) { return Character(unicode) }
            }
            throw error("非法的 UTF-16 代理对")
        }
        guard let unicode = Unicode.Scalar(code) else { throw error("非法的 Unicode 码点") }
        return Character(unicode)
    }

    mutating func parseHex4() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            guard let ch = peek, let digit = ch.hexDigitValue, ch.isHexDigit else {
                throw error("\\u 需要 4 位十六进制数字")
            }
            value = value * 16 + digit
            consume()
        }
        return value
    }

    // MARK: - 数字

    mutating func parseNumber() throws -> JSONValue {
        let start = index
        if peek == "-" { consume() }
        guard peek != nil else { throw error("负号后缺少数字") }

        if peek == "0" {
            consume()
        } else if let p = peek, p.isNumber {
            while let c = peek, c.isNumber { consume() }
        } else {
            throw error("数字格式非法", hint: "数字不能以 '\(peek ?? "?")' 开头")
        }

        if peek == "." {
            consume()
            guard let c = peek, c.isNumber else { throw error("小数点后缺少数字") }
            while let c = peek, c.isNumber { consume() }
        }

        if peek == "e" || peek == "E" {
            consume()
            if peek == "+" || peek == "-" { consume() }
            guard let c = peek, c.isNumber else { throw error("指数部分缺少数字") }
            while let c = peek, c.isNumber { consume() }
        }

        let raw = String(chars[start..<index])
        return .number(raw)
    }

    // MARK: - 字面量

    mutating func expectLiteral(_ literal: String) throws {
        for expected in literal {
            guard let ch = peek, ch == expected else {
                throw error("意外的关键字", hint: "是否想写 \(literal)？")
            }
            consume()
        }
    }

    // MARK: - 游标辅助

    private var isAtEnd: Bool { index >= chars.count }
    private var peek: Character? { index < chars.count ? chars[index] : nil }
    private mutating func consume() { index += 1 }

    private mutating func skipWhitespace() {
        while let c = peek, c == " " || c == "\t" || c == "\n" || c == "\r" { consume() }
    }

    private func error(_ message: String, hint: String? = nil) -> JSONError {
        JSONError(message: message, hint: hint, offset: index, source: chars)
    }
}
