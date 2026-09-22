//
//  HTTPClient.swift
//  devkit
//
//  M2：把 HTTPRequestModel 转成 URLRequest 发送，返回 HTTPResponseModel。
//  默认 MainActor 隔离（见 SWIFT_DEFAULT_ACTOR_ISOLATION），await 后回到主actor，安全。
//

import Foundation

/// HTTP 发送器。允许所有 HTTP 状态码（4xx/5xx 不抛错），仅传输层失败抛错。
struct HTTPClient {
    /// 请求超时（秒）。
    var timeout: TimeInterval = 30

    /// 共享会话：**禁用响应缓存**。
    ///
    /// 这是个调试工具，用户要看的是「服务器此刻真实返回了什么」。
    /// 用 `URLSession.shared`（默认 `.useProtocolCachePolicy` + 磁盘缓存）时，
    /// 重复发同一个 GET 可能直接命中缓存返回旧响应，状态码、耗时、响应体全都对不上真实情况 ——
    /// 排查问题时会被误导，而且现象是「时好时坏」，很难联想到缓存。
    /// Postman / Insomnia 这类 API 客户端同样默认绕开缓存。
    ///
    /// 注意用 `.default` 而非 `.ephemeral`：前者保留共享 cookie 存储，
    /// 依赖会话 cookie 的接口（登录后再调）才能正常工作；只关缓存，不动 cookie。
    ///
    /// `nonisolated`：`URLSession` 本身是 `Sendable`，且此实例创建后配置不再变动。
    /// 之所以需要它，是因为 `receive` 用 `@concurrent` 跑在主 actor **之外**（原因见那里的注释）。
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// 单个响应体的**保留上限**（10 MB），超出部分丢弃并置 `isBodyTruncated`。
    ///
    /// 为什么需要上限：`data(for:)` 会把**完整**响应体读进内存后才返回。调试工具很容易撞上
    /// 大响应（文件下载、日志导出、没分页的列表接口），而 `HTTPResponseModel` 会被工具实例、
    /// 历史快照、会话恢复链同时持有 —— 峰值内存是「响应体大小 × 持有份数」。
    ///
    /// 取值：覆盖绝大多数 JSON / HTML 接口响应，同时让 Pretty / Raw 的单块文本渲染保持可用
    /// （SwiftUI 渲染几十 MB 的 `Text` 本身就会卡死）。
    ///
    /// **用十进制整数（10_000_000）而不是 `10 * 1_048_576`**：界面上的大小统一走
    /// `HTTPDisplay.size`，它用 `ByteCountFormatter(countStyle: .file)`，是**十进制**口径。
    /// 写成 1 MiB 的倍数时，界面上会显示成「10.5 MB」，与文档、常量、提示条里的「10 MB」
    /// 全都对不上 —— 用户看到的是界面，所以让常量去迁就显示口径。
    static let maxBodyBytes = 10_000_000

    /// 发送请求。
    func send(_ request: HTTPRequestModel) async throws -> HTTPResponseModel {
        var urlRequest = try makeURLRequest(from: request)
        urlRequest.timeoutInterval = timeout

        let start = ContinuousClock.now
        let body: Data
        let isTruncated: Bool
        let response: URLResponse
        do {
            (body, isTruncated, response) = try await Self.receive(urlRequest, maxBytes: Self.maxBodyBytes)
        } catch let error as URLError {
            throw HTTPClientError.transport(error.localizedDescription)
        }
        let elapsed = start.duration(to: .now)
        let durationMs = Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.notHTTPResponse
        }

        let headers = httpResponse.allHeaderFields.compactMap { (key, value) -> (String, String)? in
            guard let k = key as? String else { return nil }
            return (k, "\(value)")
        }

        return HTTPResponseModel(
            statusCode: httpResponse.statusCode,
            headers: headers,
            bodyData: body,
            durationMs: durationMs,
            isBodyTruncated: isTruncated
        )
    }

    // MARK: - 收包

    /// 流式接收响应体，最多保留 `maxBytes` 字节，**到达上限即中止传输**。
    ///
    /// 不用 `data(for:)` 的原因见 `maxBodyBytes`。这里用 `bytes(for:)` 的字节序列边收边计数，
    /// 到达上限立刻 `break` —— 跳出后 `AsyncBytes` 离开作用域，其 deinit 会取消底层 task。
    ///
    /// 实测（本地服务器，声称 `Content-Length: 200 MB`，上限 10 MB）：
    /// - 服务器只发出约 15 MB 就收到连接重置，而非把 200 MB 推完；
    /// - 进程峰值内存 36 MB（基线 2.9 MB），即有界。
    ///
    /// ## 为什么必须 `@concurrent`（踩过两次，第二次才找到真因）
    ///
    /// 本工程开了 `SWIFT_APPROACHABLE_CONCURRENCY = YES`，它在 Swift 6.2 下启用
    /// `NonisolatedNonsendingByDefault` —— 于是 **`nonisolated` 函数会沿用调用方的执行器**。
    /// `send` 在主 actor 上，所以只标 `nonisolated` 的话 `receive` **仍然跑在主 actor 上**：
    /// 循环每取一个字节就 hop 一次主 actor（实测单次约 5~6 µs），
    /// 3 MB 要 17.5s，10 MB 直接撞满 30s 请求超时。
    ///
    /// 现象极具误导性：自检里 673 字节的 `small.json` 一切正常，只有 12 MB 的 `big.txt` 报
    /// "The request timed out"，看着像服务端或夹具的问题，其实与服务端毫无关系。
    /// 而且**独立脚本里复刻同样的代码却是快的**（0.37s）—— 因为脚本没开这个 upcoming feature，
    /// `nonisolated` 在那里的语义是「切到全局执行器」。排查时别忽略编译设置差异。
    ///
    /// `@concurrent`（SE-0461）是这种情况的正解：显式要求落到全局并发执行器。
    /// 对照实验（同一循环体、同一夹具、同一编译设置）：
    ///
    /// | 写法 | 3 MB 耗时 |
    /// | --- | --- |
    /// | `nonisolated`（从主 actor 调用） | 17.5s |
    /// | `nonisolated` + `Task.detached` | 0.14s |
    /// | `@concurrent` | 0.14s |
    ///
    /// 采用 `@concurrent`：一个属性就够，不必把调用方也改写成 `Task.detached`。
    /// 实测封顶 10 MB 约 0.37s（≈27 MB/s），且不再占用主线程。
    /// 小响应（< 1 MB）的额外开销在几十毫秒内，相对网络往返可忽略。
    ///
    /// 若将来这个吞吐成为问题，可改为 task 级 `URLSessionDataDelegate` 分块收集 ——
    /// 全速、同样能在超限时取消，代价是要桥接 delegate 队列与 actor 隔离。
    @concurrent
    private static func receive(
        _ urlRequest: URLRequest,
        maxBytes: Int
    ) async throws -> (body: Data, isTruncated: Bool, response: URLResponse) {
        let (bytes, response) = try await session.bytes(for: urlRequest)
        var body = Data()
        body.reserveCapacity(min(maxBytes, 256 * 1024))
        var isTruncated = false
        for try await byte in bytes {
            if body.count >= maxBytes {
                isTruncated = true
                break
            }
            body.append(byte)
        }
        return (body, isTruncated, response)
    }

    // MARK: - URLRequest 构造

    /// 由请求模型构造 URLRequest（应用 query、headers、auth、body）。
    func makeURLRequest(from request: HTTPRequestModel) throws -> URLRequest {
        let finalURLString = request.appliedURLString
        guard !finalURLString.isEmpty,
              let url = URL(string: finalURLString),
              url.scheme != nil, url.host != nil
        else {
            throw HTTPClientError.invalidURL(finalURLString)
        }

        var req = URLRequest(url: url)
        req.httpMethod = request.method.trimmingCharacters(in: .whitespaces).uppercased()

        // 自定义 headers
        for header in request.enabledHeaders {
            req.setValue(header.value, forHTTPHeaderField: header.key)
        }

        // 认证：Authorization
        if let authHeader = request.auth.headerValue {
            req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        // Body
        if !request.body.isEmpty, let payload = request.body.encodedPayload,
           let bodyData = payload.data(using: .utf8) {
            if let contentType = request.body.contentType {
                req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            req.httpBody = bodyData
        }

        return req
    }
}

enum HTTPClientError: LocalizedError {
    case invalidURL(String)
    case notHTTPResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "URL 无效或以空值开始，请填写包含协议头的完整地址：\(raw.isEmpty ? "(空)" : raw)"
        case .notHTTPResponse:
            return "响应不是有效的 HTTP 响应"
        case .transport(let message):
            return "网络请求失败：\(message)"
        }
    }
}
