//
//  HTTPRequestModel.swift
//  devkit
//
//  M2：HTTP 请求的数据模型。值类型，仅在 MainActor 上下文使用（与既有会话快照一致）。
//

import Foundation

/// 常用方法预设；请求模型内部以字符串存储，以便支持自定义方法。
enum HTTPMethodPreset: String, CaseIterable, Identifiable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
    case head = "HEAD"
    case options = "OPTIONS"

    var id: String { rawValue }
    var label: String { rawValue }
}

/// 键值对（Params 与 Headers 复用）；支持单行启用/禁用。
struct HTTPKV: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var key: String = ""
    var value: String = ""
    var enabled: Bool = true

    var isPlaceholder: Bool { key.isEmpty && value.isEmpty }
}

/// 请求体。M2 覆盖 none / json / form(urlencoded) / raw；multipart 与 GraphQL 留待 M5。
struct HTTPBodyModel: Hashable, Codable {
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case none = "无"
        case json = "JSON"
        case form = "Form URL-encoded"
        case raw = "Raw"
        var id: String { rawValue }
    }

    var kind: Kind = .none
    /// JSON / Raw 的文本内容。
    var text: String = ""
    /// form-urlencoded 的字段。
    var formFields: [HTTPKV] = []

    var isEmpty: Bool {
        switch kind {
        case .none: return true
        case .json, .raw: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .form: return formFields.filter { $0.enabled && !$0.key.isEmpty }.isEmpty
        }
    }

    var contentType: String? {
        switch kind {
        case .none: return nil
        case .json: return "application/json"
        case .form: return "application/x-www-form-urlencoded"
        case .raw: return "text/plain"
        }
    }

    /// 编码后的请求体字符串（form 做 URL 编码）；空体返回 nil。
    var encodedPayload: String? {
        switch kind {
        case .none:
            return nil
        case .json, .raw:
            return text.isEmpty ? nil : text
        case .form:
            let pairs = formFields
                .filter { $0.enabled && !$0.key.isEmpty }
                .map { "\(HTTPQueryUtil.percentEncode($0.key))=\(HTTPQueryUtil.percentEncode($0.value))" }
            return pairs.isEmpty ? nil : pairs.joined(separator: "&")
        }
    }
}

/// 认证：M2 支持 Bearer 与 Basic（自动生成 Authorization 头）。
struct HTTPAuthModel: Hashable, Codable {
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case none = "无"
        case bearer = "Bearer Token"
        case basic = "Basic Auth"
        var id: String { rawValue }
    }

    var kind: Kind = .none
    var token: String = ""
    var username: String = ""
    var password: String = ""

    /// 生成的 Authorization 头值；未配置返回 nil。
    var headerValue: String? {
        switch kind {
        case .none:
            return nil
        case .bearer:
            return token.isEmpty ? nil : "Bearer \(token)"
        case .basic:
            guard !username.isEmpty || !password.isEmpty else { return nil }
            let pair = "\(username):\(password)"
            return "Basic \(Data(pair.utf8).base64EncodedString())"
        }
    }
}

/// 完整请求模型。
struct HTTPRequestModel: Hashable, Codable {
    var method: String = "GET"
    var urlString: String = ""
    var params: [HTTPKV] = []
    var headers: [HTTPKV] = []
    var body: HTTPBodyModel = HTTPBodyModel()
    var auth: HTTPAuthModel = HTTPAuthModel()

    var trimmedURLString: String { urlString.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isEmpty: Bool { trimmedURLString.isEmpty }

    /// 启用 headers 的 key/value 对（不含空行）。
    var enabledHeaders: [(key: String, value: String)] {
        headers.filter { $0.enabled && !$0.key.isEmpty }.map { ($0.key, $0.value) }
    }

    /// 合并 URL 自带 query 与启用参数后的最终请求 URL。
    /// 参数表格优先覆盖同名项；被禁用的参数会从 query 中移除。
    var appliedURLString: String {
        guard var components = URLComponents(string: trimmedURLString) else { return trimmedURLString }
        var items = components.queryItems ?? []

        for param in params where param.enabled && !param.key.isEmpty {
            let item = URLQueryItem(name: param.key, value: param.value.isEmpty ? nil : param.value)
            if let idx = items.firstIndex(where: { $0.name == param.key }) {
                items[idx] = item
            } else {
                items.append(item)
            }
        }

        let disabledKeys = Set(params.filter { !$0.enabled }.map(\.key))
        if !disabledKeys.isEmpty {
            items.removeAll { disabledKeys.contains($0.name) }
        }

        components.queryItems = items.isEmpty ? nil : items
        return components.url?.absoluteString ?? trimmedURLString
    }

    /// 把当前 URL 上的 query 参数拉取到参数表格（跳过已存在的 key）。
    mutating func syncQueryToParams() {
        guard let components = URLComponents(string: trimmedURLString),
              let items = components.queryItems, !items.isEmpty
        else { return }
        for item in items where !params.contains(where: { $0.key == item.name }) {
            params.append(HTTPKV(key: item.name, value: item.value ?? "", enabled: true))
        }
    }
}

/// URL / form 编码相关的小工具。
enum HTTPQueryUtil {
    /// 用于 query / form 值的百分号编码（保留 unreserved 字符）。
    static func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
