//
//  HTTPResponseModel.swift
//  devkit
//
//  M2：HTTP 响应模型。仅在 MainActor 上下文构造。运行时用 HTTPResponseModel；
//  写入历史时转成可 Codable 的 HTTPResponseSnapshot（含响应头与响应体）。
//

import Foundation

/// 一次 HTTP 请求的响应结果。
struct HTTPResponseModel {
    /// HTTP 状态码；网络层未返回 HTTP 响应时为 0。
    let statusCode: Int
    /// 全部响应头（保持原始大小写）。
    let headers: [(key: String, value: String)]
    /// 原始响应体。
    let bodyData: Data
    /// 往返耗时（毫秒）。
    let durationMs: Int

    // MARK: - 派生指标

    var sizeBytes: Int { bodyData.count }

    var contentType: String? {
        headers.first { $0.key.lowercased() == "content-type" }?.value
    }

    /// 状态码分类，用于颜色分级。
    var statusCategory: StatusCategory {
        switch statusCode {
        case 0: return .transportError
        case 100..<200: return .informational
        case 200..<300: return .success
        case 300..<400: return .redirection
        case 400..<500: return .clientError
        case 500..<600: return .serverError
        default: return .unknown
        }
    }

    enum StatusCategory: Sendable {
        case informational, success, redirection, clientError, serverError, transportError, unknown

        var label: String {
            switch self {
            case .informational: return "信息"
            case .success: return "成功"
            case .redirection: return "重定向"
            case .clientError: return "客户端错误"
            case .serverError: return "服务器错误"
            case .transportError: return "网络错误"
            case .unknown: return "未知"
            }
        }
    }

    // MARK: - 视图辅助

    /// UTF-8 可解码的文本；二进制内容返回 nil。
    var bodyText: String? {
        String(data: bodyData, encoding: .utf8)
    }

    var isTextual: Bool { bodyText != nil }

    /// 尝试把响应体当作 JSON 解析并美化输出（缩进 + 键排序）；非对象/数组返回 nil。
    var prettyJSON: String? {
        guard !bodyData.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: bodyData, options: [.fragmentsAllowed]),
              object is [String: Any] || object is [Any]
        else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var isHTML: Bool {
        guard let ct = contentType?.lowercased() else { return false }
        return ct.contains("text/html") || ct.contains("application/xhtml")
    }

    var isImage: Bool {
        contentType?.lowercased().hasPrefix("image/") ?? false
    }
}

/// 可持久化的响应快照。`HTTPResponseModel` 不可 Codable（headers 为元组数组），
/// 故写入历史时转成本结构；响应体按上限截断，避免 DB 膨胀。
struct HTTPResponseSnapshot: Codable, Hashable {
    var statusCode: Int
    var durationMs: Int
    var headers: [HTTPKV]
    var bodyData: Data
    /// 响应体是否因超过上限被截断。
    var isBodyTruncated: Bool

    /// 从运行时响应构建快照；`maxBodyBytes` 为响应体保留上限。
    init(from response: HTTPResponseModel, maxBodyBytes: Int) {
        self.statusCode = response.statusCode
        self.durationMs = response.durationMs
        self.headers = response.headers.map { HTTPKV(key: $0.key, value: $0.value) }
        if response.bodyData.count > maxBodyBytes {
            self.bodyData = Data(response.bodyData.prefix(maxBodyBytes))
            self.isBodyTruncated = true
        } else {
            self.bodyData = response.bodyData
            self.isBodyTruncated = false
        }
    }

    // MARK: - 视图辅助（与 HTTPResponseModel 对齐）

    var sizeBytes: Int { bodyData.count }

    var contentType: String? {
        headers.first { $0.key.lowercased() == "content-type" }?.value
    }

    var bodyText: String? {
        String(data: bodyData, encoding: .utf8)
    }

    /// 尝试把响应体当 JSON 美化输出；非对象/数组返回 nil。
    var prettyJSON: String? {
        guard !bodyData.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: bodyData, options: [.fragmentsAllowed]),
              object is [String: Any] || object is [Any]
        else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
