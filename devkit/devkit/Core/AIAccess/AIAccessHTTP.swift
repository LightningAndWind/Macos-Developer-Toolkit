//
//  AIAccessHTTP.swift
//  devkit
//
//  AI 接入的 HTTP 监听层：NWListener 仅绑定 127.0.0.1，配一套极简 HTTP/1.1 解析。
//  手写而非引入 swift-nio HTTP：本服务只服务本机 MCP 客户端、单一 JSON 端点、
//  响应一律 Connection: close（每连接一个请求），解析面很小；Network.framework 是系统框架，
//  零新依赖（工程依赖极简的既定风格）。
//
//  线程模型：全部连接回调在专用串行队列；请求解析在该队列完成；业务路由在 Task 里跑
//  （可长时间执行，不阻塞其它连接），应答统一 dispatch 回队列发送。
//

import Foundation
import Network

// MARK: - 请求 / 应答模型

nonisolated struct MCPHTTPRequest: Sendable {
    var method: String
    /// 原始路径（含 query，如 `/mcp?token=x`）。
    var rawPath: String
    /// 头字段名已转小写。
    var headers: [String: String]
    var body: Data

    /// 去掉 query 的路径。
    var path: String {
        String(rawPath.split(separator: "?").first ?? "")
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

nonisolated struct MCPHTTPResponse: Sendable {
    var status: Int
    var reason: String
    var contentType: String
    var body: Data

    static func json(status: Int, reason: String, text: String) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, reason: reason,
                        contentType: "application/json",
                        body: Data(text.utf8))
    }
}

// MARK: - 监听器

nonisolated final class MCPHTTPListener: @unchecked Sendable {
    /// 业务路由：解析完的完整请求 → 应答（在任意执行器上运行，允许长时间执行）。
    typealias RouteHandler = @Sendable (MCPHTTPRequest) async -> MCPHTTPResponse
    /// 状态回报（succeeded=false 时 message 携带原因），在监听队列上回调，接收方自行 hop。
    typealias StateHandler = @Sendable (_ succeeded: Bool, _ message: String?) -> Void

    private let queue = DispatchQueue(label: "devkit.ai.http")
    private let handler: RouteHandler
    private let onState: StateHandler
    private var listener: NWListener?
    /// 活跃连接（仅 queue 上触碰）：连接对象必须被强持有，其回调才能活着处理数据。
    private var activeConnections: [MCPHTTPConnection] = []

    init(handler: @escaping RouteHandler, onState: @escaping StateHandler) {
        self.handler = handler
        self.onState = onState
    }

    /// 端口冲突等启动问题经 onState(succeeded: false, message:) 回报；ready 经 (true, nil)。
    func start(port: UInt16) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 只绑回环：AI 客户端与本机通信，绝不对外网暴露。
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                               port: NWEndpoint.Port(rawValue: port) ?? 51790)
        guard let listener = try? NWListener(using: parameters) else {
            onState(false, "无法创建监听器（端口 \(port)）")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [onState] state in
            switch state {
            case .ready:
                onState(true, nil)
            case .failed(let error):
                onState(false, error.localizedDescription)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            guard let self else { return }
            for conn in self.activeConnections { conn.forceClose() }
            self.activeConnections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        // 必须把连接对象挂进数组强持有：accept 返回后若无引用，连接对象立刻析构，
        // 它的 receive 回调全是 weak-self，之后所有数据都会被静默丢弃（表现为请求无响应、
        // 连接堆积 CLOSE_WAIT）。连接结束时经 onFinished 回调摘除。
        let conn = MCPHTTPConnection(connection: connection, queue: queue, handler: handler) { [weak self] finished in
            self?.releaseConnection(finished)
        }
        activeConnections.append(conn)
        conn.start()
    }

    private func releaseConnection(_ conn: MCPHTTPConnection) {
        activeConnections.removeAll { $0 === conn }
    }
}

// MARK: - 单连接处理

nonisolated final class MCPHTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: MCPHTTPListener.RouteHandler
    /// 连接终结时回调（在 queue 上），监听器借此把它从强持有数组摘除。
    private let onFinished: @Sendable (MCPHTTPConnection) -> Void

    /// 以下缓冲与标志只在 `queue` 上触碰。
    private var buffer = Data()
    private var sentContinue = false
    private var requestInProgress = false
    private var finished = false

    private static let maxHeaderLength = 16 * 1024
    private static let maxBodyLength = 4 * 1024 * 1024

    init(connection: NWConnection,
         queue: DispatchQueue,
         handler: @escaping MCPHTTPListener.RouteHandler,
         onFinished: @escaping @Sendable (MCPHTTPConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.onFinished = onFinished
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    /// 服务停止时由监听器调用：直接拆连接。
    func forceClose() {
        finish()
    }

    /// 幂等收尾：关连接 + 通知监听器摘除强引用。
    private func finish() {
        guard !finished else { return }
        finished = true
        connection.cancel()
        onFinished(self)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            if error != nil || isComplete {
                self.finish()
                return
            }
            guard !self.requestInProgress else { return }
            self.receiveNext()
        }
    }

    /// 尝试从缓冲解析出一个完整请求；不足则继续收。已分发请求后忽略后续数据（应答即关连接）。
    private func processBuffer() {
        guard !requestInProgress else { return }
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeaderLength {
                sendAndClose(MCPHTTPResponse.json(status: 431, reason: "Request Header Fields Too Large",
                                                   text: #"{"error":"header too large"}"#))
            }
            return
        }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            sendAndClose(MCPHTTPResponse.json(status: 400, reason: "Bad Request", text: #"{"error":"bad header"}"#))
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard lines.count >= 1 else { return }
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else {
            sendAndClose(MCPHTTPResponse.json(status: 400, reason: "Bad Request", text: #"{"error":"bad request line"}"#))
            return
        }
        let method = requestLine[0]
        let rawPath = requestLine[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // curl 对 >1KB 的 POST body 会先发 Expect: 100-continue 等待放行。
        if headers["expect"]?.lowercased().contains("100-continue") == true, !sentContinue {
            sentContinue = true
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if contentLength > Self.maxBodyLength {
            sendAndClose(MCPHTTPResponse.json(status: 413, reason: "Payload Too Large", text: #"{"error":"body too large"}"#))
            return
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return } // body 未收全

        let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: contentLength))
        let request = MCPHTTPRequest(method: method, rawPath: rawPath, headers: headers, body: body)

        requestInProgress = true
        Task { [handler, request] in
            let response = await handler(request)
            self.dispatchSend(response)
        }
    }

    private func dispatchSend(_ response: MCPHTTPResponse) {
        queue.async { [weak self] in
            self?.sendAndClose(response)
        }
    }

    /// 应答一律 Connection: close：客户端对每个请求新建连接，服务端免 keep-alive 状态机。
    private func sendAndClose(_ response: MCPHTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }
}
