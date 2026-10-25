//
//  MCPProtocol.swift
//  devkit
//
//  MCP（Model Context Protocol，Streamable HTTP 传输）的最小服务端实现：JSON-RPC 2.0 over
//  HTTP POST。手写而非引 SDK —— 依赖极简是本工程的既定风格（SQLite / JSON 解析均为手写），
//  而这里只需要 initialize / tools/list / tools/call / ping 四个方法。
//
//  无状态设计：不分配 Mcp-Session-Id，每个 POST 独立处理（工具本身不依赖会话握手状态）。
//  协议版本：回显客户端请求值（已知版本集合内），未知则回 2025-06-18。
//  通知（无 id 的消息）按规范返回 202 Accepted 空 body。
//

import Foundation

// MARK: - 动态 JSON 值

/// JSON-RPC 消息里的任意 JSON 值（编解码对称）。nonisolated：协议层在任意执行器上解析。
nonisolated enum MCPJSON: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([MCPJSON])
    case object([String: MCPJSON])

    var isNull: Bool { if case .null = self { return true }; return false }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [MCPJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: MCPJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    subscript(key: String) -> MCPJSON? {
        objectValue?[key]
    }

    /// 序列化为紧凑 JSON 文本（不转义正斜杠，路径保持 `/home/x` 而非 `\/home\/x`）。
    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated extension MCPJSON: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([MCPJSON].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: MCPJSON].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "不支持的 JSON 值")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - 路由

nonisolated enum MCPRouter {
    /// 本服务端理解的协议版本；未知请求版本以此回应。
    static let latestProtocolVersion = "2025-06-18"
    static let knownProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]

    /// 一条 HTTP POST 的处理结果。
    struct Outcome: Sendable {
        var status: Int
        var body: Data?
    }

    /// 入口：解析 body（单条或批量）并分发。
    static func handle(body: Data) async -> Outcome {
        guard let parsed = try? JSONDecoder().decode(MCPJSON.self, from: body) else {
            let response = respond(errorCode: -32700, message: "Parse error", id: .null)
            return Outcome(status: 200, body: try? JSONEncoder().encode(response))
        }

        if let items = parsed.arrayValue {
            // 批量：逐条处理，通知（无 id）丢弃；全部是通知 → 202。
            var responses: [MCPJSON] = []
            for item in items {
                if let response = await handleOne(item), !response.isNull {
                    responses.append(response)
                }
            }
            if responses.isEmpty { return Outcome(status: 202, body: nil) }
            let payload = MCPJSON.array(responses)
            return Outcome(status: 200, body: try? JSONEncoder().encode(payload))
        }

        if let response = await handleOne(parsed), !response.isNull {
            return Outcome(status: 200, body: try? JSONEncoder().encode(response))
        }
        return Outcome(status: 202, body: nil)
    }

    /// 处理单条消息；通知返回 nil。
    private static func handleOne(_ message: MCPJSON) async -> MCPJSON? {
        guard let obj = message.objectValue else {
            return respond(errorCode: -32600, message: "Invalid Request", id: .null)
        }
        let id = obj["id"] ?? .null
        guard let method = obj["method"]?.stringValue else {
            return respond(errorCode: -32600, message: "Invalid Request", id: id)
        }
        let params = obj["params"]?.objectValue ?? [:]

        // 通知：无 id 的消息只接收，不回应。
        if case .null = id { return nil }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue
            let version = requested.map { knownProtocolVersions.contains($0) ? $0 : latestProtocolVersion }
                ?? latestProtocolVersion
            return respond(id: id, result: .object([
                "protocolVersion": .string(version),
                "capabilities": .object([
                    "tools": .object(["listChanged": .bool(false)]),
                ]),
                "serverInfo": .object([
                    "name": .string("devkit"),
                    "version": .string("1.0.0"),
                ]),
            ]))

        case "ping":
            return respond(id: id, result: .object([:]))

        case "tools/list":
            let tools = await MCPToolCatalog.shared.definitionsJSON
            return respond(id: id, result: .object(["tools": .array(tools)]))

        case "tools/call":
            let name = params["name"]?.stringValue ?? ""
            let arguments = params["arguments"] ?? .object([:])
            let outcome = await MCPToolCatalog.shared.call(name: name, arguments: arguments)
            var result: [String: MCPJSON] = [
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(outcome.text),
                ])]),
            ]
            if outcome.isError { result["isError"] = .bool(true) }
            return respond(id: id, result: .object(result))

        default:
            return respond(errorCode: -32601, message: "Method not found: \(method)", id: id)
        }
    }

    // MARK: - 应答构造

    private static func respond(id: MCPJSON, result: MCPJSON) -> MCPJSON {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result,
        ])
    }

    private static func respond(errorCode: Int, message: String, id: MCPJSON) -> MCPJSON {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .int(Int64(errorCode)),
                "message": .string(message),
            ]),
        ])
    }
}
