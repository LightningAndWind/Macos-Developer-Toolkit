//
//  AIAccessServer.swift
//  devkit
//
//  AI 接入的编排单例：配置持久化（kv 表）、HTTP 监听生命周期、Token 鉴权、审计日志、
//  会话回收定时器。默认关闭；在设置页显式开启后，随 app 启动自动拉起（AppState 就绪时）。
//
//  安全模型：仅绑定 127.0.0.1 + Bearer Token（或 ?token= 兜底）；所有工具输出经
//  MCPToolCatalog → Redactor 脱敏，凭据不进入模型上下文。这是「上下文卫生」层：
//  防的是凭据流经对话记录 / 云端日志，防不了本地已有任意 shell 权限的恶意程序直读数据库。
//

import Foundation
import Observation

@MainActor
@Observable
final class AIAccessServer {
    static let shared = AIAccessServer()
    static let defaultPort = 51790

    // MARK: - 状态（设置页直读直绑）

    private(set) var enabled = false
    private(set) var port: Int = AIAccessServer.defaultPort
    private(set) var token = ""
    private(set) var running = false
    private(set) var lastError: String?

    struct AuditEntry: Identifiable {
        let id = UUID()
        let time = Date()
        let tool: String
        let summary: String
        let ok: Bool
        let durationMS: Int
    }

    private(set) var auditLog: [AuditEntry] = []
    private static let auditCap = 200

    private var listener: MCPHTTPListener?
    private var reaper: Timer?

    private enum KVKeys {
        static let enabled = "ai.mcp.enabled"
        static let port = "ai.mcp.port"
        static let token = "ai.mcp.token"
    }

    private init() {}

    // MARK: - 配置

    /// 从 kv 读配置（app 就绪后调用；也供设置页每次打开时刷新）。
    func loadConfig() {
        guard DatabaseManager.shared.isOpen else { return }
        enabled = (try? DatabaseManager.shared.getKV(key: KVKeys.enabled))
            .flatMap { String(decoding: $0, as: UTF8.self) } == "1"
        if let portData = (try? DatabaseManager.shared.getKV(key: KVKeys.port)),
           let stored = Int(String(decoding: portData, as: UTF8.self)),
           (1024...65535).contains(stored) {
            port = stored
        }
        if let tokenData = (try? DatabaseManager.shared.getKV(key: KVKeys.token)) {
            token = String(decoding: tokenData, as: UTF8.self)
        }
    }

    private func persist(_ key: String, _ value: String) {
        try? DatabaseManager.shared.putKV(key: key, value: Data(value.utf8))
    }

    /// 开关（设置页绑定）。
    func setEnabled(_ on: Bool) {
        enabled = on
        persist(KVKeys.enabled, on ? "1" : "0")
        if on {
            if token.isEmpty { regenerateToken(persist: false) }
            ensureBridgeScript()
            start()
        } else {
            stop()
        }
    }

    /// 应用端口变更（设置页提交时）；运行中则重启生效。
    func applyPort(_ newPort: Int) {
        guard (1024...65535).contains(newPort), newPort != port else { return }
        port = newPort
        persist(KVKeys.port, "\(newPort)")
        if running { restart() }
    }

    /// 重新生成 Token；旧的立即作废（运行中则重启以换掉路由闭包里的捕获值）。
    func regenerateToken(persist: Bool = true) {
        token = Self.generateToken()
        if persist { self.persist(KVKeys.token, token) }
        if running { restart() }
    }

    private static func generateToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in
            let byte = UInt8.random(in: 0...255, using: &rng)
            return String(format: "%02x", byte)
        }.joined()
    }

    // MARK: - 生命周期

    /// AppState 就绪后调用：已启用则拉起。
    func autostartIfNeeded() {
        loadConfig()
        if enabled {
            ensureBridgeScript()
            start()
        }
    }

    func start() {
        guard listener == nil else { return }
        if token.isEmpty { regenerateToken(persist: true) }
        lastError = nil
        let currentToken = token
        let listener = MCPHTTPListener(
            handler: { request in
                await Self.route(request, token: currentToken)
            },
            onState: { [weak self] succeeded, message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if succeeded {
                        self.running = true
                        self.lastError = nil
                    } else {
                        self.running = false
                        self.listener = nil
                        self.lastError = message ?? "未知错误"
                    }
                }
            })
        self.listener = listener
        listener.start(port: UInt16(clamping: port))

        startReaper()
    }

    func stop() {
        listener?.stop()
        listener = nil
        running = false
        stopReaper()
        Task { await SSHSessionRegistry.shared.closeAll() }
    }

    /// 停止并清理（数据目录重置 / app 退出）。
    func shutdown() {
        enabled = false
        stop()
    }

    private func restart() {
        listener?.stop()
        listener = nil
        running = false
        start()
    }

    // MARK: - 路由（鉴权 + 分发）

    /// 独立静态函数：路由闭包捕获的是 token 值拷贝，避免跨 actor 访问可变状态。
    private nonisolated static func route(_ request: MCPHTTPRequest, token: String) async -> MCPHTTPResponse {
        if request.path == "/healthz", request.method == "GET" {
            return MCPHTTPResponse.json(status: 200, reason: "OK", text: #"{"status":"ok"}"#)
        }

        let path = request.path
        guard path == "/mcp" || path == "/mcp/" else {
            return MCPHTTPResponse.json(status: 404, reason: "Not Found", text: #"{"error":"not found"}"#)
        }
        guard request.method == "POST" else {
            // Streamable HTTP 无状态服务端：GET（SSE 订阅）按规范允许返回 405。
            return MCPHTTPResponse.json(status: 405, reason: "Method Not Allowed", text: #"{"error":"POST only"}"#)
        }

        guard authorized(request, token: token) else {
            return MCPHTTPResponse(status: 401, reason: "Unauthorized",
                                   contentType: "application/json",
                                   body: Data(#"{"error":"unauthorized"}"#.utf8))
        }

        let outcome = await MCPRouter.handle(body: request.body)
        if let body = outcome.body {
            return MCPHTTPResponse(status: outcome.status, reason: reasonText(outcome.status),
                                   contentType: "application/json", body: body)
        }
        return MCPHTTPResponse(status: 202, reason: "Accepted", contentType: "application/json", body: Data())
    }

    private nonisolated static func authorized(_ request: MCPHTTPRequest, token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if let header = request.header("authorization"), header == "Bearer \(token)" {
            return true
        }
        // 兜底：部分客户端配不了自定义头 → ?token=
        let parts = request.rawPath.split(separator: "?", maxSplits: 1)
        if parts.count > 1 {
            let query = parts[1]
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.first == "token", kv.count == 2,
                   kv.last.map(String.init) == token || kv.last.map(String.init)?.removingPercentEncoding == token {
                    return true
                }
            }
        }
        return false
    }

    private nonisolated static func reasonText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        default: return "Error"
        }
    }

    // MARK: - 审计

    func recordAudit(tool: String, summary: String, ok: Bool, durationMS: Int) {
        auditLog.append(AuditEntry(tool: tool, summary: summary, ok: ok, durationMS: durationMS))
        if auditLog.count > Self.auditCap {
            auditLog.removeFirst(auditLog.count - Self.auditCap)
        }
    }

    func clearAudit() {
        auditLog.removeAll()
    }

    // MARK: - 回收定时器

    private func startReaper() {
        guard reaper == nil else { return }
        reaper = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                await SSHSessionRegistry.shared.reapIdle()
            }
        }
    }

    private func stopReaper() {
        reaper?.invalidate()
        reaper = nil
    }

    // MARK: - 展示辅助

    var endpointURL: String {
        "http://127.0.0.1:\(port)/mcp"
    }

    // MARK: - stdio 桥接脚本

    /// 桥接脚本版本号（内容变更时递增，触发重新写入）。
    static let bridgeScriptVersion = 2

    /// 桥接脚本落盘位置（Application Support/devkit/）。数据目录可重置，故不放数据目录。
    static var bridgeScriptURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("devkit", isDirectory: true)
            .appendingPathComponent("mcp-stdio-bridge.sh")
    }

    /// 启用 AI 接入时确保桥接脚本存在且为当前版本（幂等）。
    @discardableResult
    func ensureBridgeScript() -> Bool {
        let url = Self.bridgeScriptURL
        let fm = FileManager.default
        do {
            let dir = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            // 版本不匹配（或不存在）则重写；每次都改 mtime 会让脚本无谓变化，先比对。
            let expectedHeader = "# version: \(Self.bridgeScriptVersion)\n"
            if let existing = try? String(contentsOf: url, encoding: .utf8),
               existing.hasPrefix("#!/bin/bash\n# devkit MCP stdio bridge\n\(expectedHeader)") {
                return true
            }
            try Self.bridgeScriptContents.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return true
        } catch {
            lastError = "生成 stdio 桥接脚本失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 桥接脚本内容：stdin 逐行读 JSON-RPC 消息 → POST 到本地 HTTP 端点 → 应答写回 stdout。
    /// 200 输出应答体；202（通知）不输出；失败时回一条 JSON-RPC 错误便于客户端诊断。
    static let bridgeScriptContents: String = """
        #!/bin/bash
        # devkit MCP stdio bridge
        # version: \(bridgeScriptVersion)
        # 由 devkit 自动生成：把 stdio 的 JSON-RPC 消息逐条转发给 devkit 内置 MCP 服务。
        # 请勿手改（重新启用 AI 接入时会被覆盖）。

        PORT="51790"
        TOKEN=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --port) PORT="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            *) shift ;;
          esac
        done

        URL="http://127.0.0.1:${PORT}/mcp"
        BODY_FILE=$(mktemp)
        trap 'rm -f "$BODY_FILE"' EXIT

        # `|| [ -n "$line" ]`：最后一行无换行符结尾时 read 返回非零，但内容已读入——
        # 不加会把 EOF 前的最后一条消息整条吞掉。
        while IFS= read -r line || [ -n "$line" ]; do
          [ -z "$line" ] && continue
          http_code=$(curl -s -m 660 -o "$BODY_FILE" -w '%{http_code}' -X POST "$URL" \\
            -H "Content-Type: application/json" \\
            -H "Authorization: Bearer ${TOKEN}" \\
            --data-binary "$line")
          case "$http_code" in
            200) cat "$BODY_FILE"; printf '\\n' ;;
            202) ;; # 通知无需应答
            000) printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"devkit MCP 未响应：请确认 devkit 已启动且设置页 AI 接入已开启"}}\\n' ;;
            *) printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"devkit MCP HTTP %s"}}\\n' "$http_code" ;;
          esac
        done
        """

    /// 客户端配置（ZCode：~/.zcode/cli/config.json → mcp.servers，stdio 形式）。
    func zcodeConfigJSON() -> String {
        """
        {
          "mcp": {
            "servers": {
              "devkit": {
                "type": "stdio",
                "command": "\(Self.bridgeScriptURL.path)",
                "args": ["--port", "\(port)", "--token", "\(token)"]
              }
            }
          }
        }
        """
    }

    /// 通用 mcpServers 片段（Claude Code / Cursor 等，stdio 形式）。
    func genericConfigJSON() -> String {
        """
        {
          "mcpServers": {
            "devkit": {
              "type": "stdio",
              "command": "\(Self.bridgeScriptURL.path)",
              "args": ["--port", "\(port)", "--token", "\(token)"]
            }
          }
        }
        """
    }
}
