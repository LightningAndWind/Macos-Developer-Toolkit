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

    /// 发送请求。
    func send(_ request: HTTPRequestModel) async throws -> HTTPResponseModel {
        var urlRequest = try makeURLRequest(from: request)
        urlRequest.timeoutInterval = timeout

        let start = ContinuousClock.now
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
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
            bodyData: data,
            durationMs: durationMs
        )
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
