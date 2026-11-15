//
//  HTTPRequestModel.swift
//  devkit
//
//  M2：HTTP 请求的数据模型。值类型，仅在 MainActor 上下文使用（与既有会话快照一致）。
//

import Foundation
import UniformTypeIdentifiers

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

/// multipart 的文件条目：存绝对路径，发送时按路径读取（应用未开沙盒，可直接读）。
struct HTTPMultipartFile: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    /// 表单字段名（服务端接收端的名字，如 `file` / `avatar`）。
    var fieldName: String = "file"
    /// 文件绝对路径。
    var filePath: String = ""
    /// 上传时使用的 filename；空 = 取路径末段。
    var fileName: String = ""
    /// Content-Type；空 = 发送时按扩展名推断（`application/octet-stream` 兜底）。
    var mimeType: String = ""
    var enabled: Bool = true

    var isPlaceholder: Bool { filePath.isEmpty && fieldName.isEmpty }

    /// 实际上传时的 filename：显式填了就用它，否则取路径末段。
    var effectiveFileName: String {
        fileName.isEmpty ? (filePath as NSString).lastPathComponent : fileName
    }

    /// 发送时实际使用的 Content-Type：显式填写优先，否则按 filename 扩展名推断，
    /// 兜底 `application/octet-stream`。发送（HTTPClient）与 cURL 导出共用同一推导，
    /// 保证「发出去的」和「复制出来的命令」行为一致。
    var effectiveMimeType: String {
        if !mimeType.isEmpty { return mimeType }
        let ext = (effectiveFileName as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// 该条目会作为一个部件参与发送吗（启用 + 字段名与路径都填了）。
    var isActive: Bool {
        enabled && !fieldName.isEmpty && !filePath.isEmpty
    }
}

/// 请求体。M2 覆盖 none / json / form(urlencoded) / raw；后续补齐 multipart（Form-Data）。
struct HTTPBodyModel: Hashable, Codable {
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case none = "无"
        case json = "JSON"
        case form = "Form URL-encoded"
        case raw = "Raw"
        case multipart = "Form-Data"
        var id: String { rawValue }
    }

    var kind: Kind = .none
    /// JSON / Raw 的文本内容。
    var text: String = ""
    /// form-urlencoded 的字段。
    var formFields: [HTTPKV] = []
    /// multipart 的文本字段。
    var multipartFields: [HTTPKV] = []
    /// multipart 的文件条目。
    var multipartFiles: [HTTPMultipartFile] = []

    var isEmpty: Bool {
        switch kind {
        case .none: return true
        case .json, .raw: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .form: return formFields.filter { $0.enabled && !$0.key.isEmpty }.isEmpty
        case .multipart:
            let hasField = multipartFields.contains { $0.enabled && !$0.key.isEmpty }
            return !hasField && !multipartFiles.contains { $0.isActive }
        }
    }

    var contentType: String? {
        switch kind {
        case .none: return nil
        case .json: return "application/json"
        case .form: return "application/x-www-form-urlencoded"
        case .raw: return "text/plain"
        // multipart 的 Content-Type 需带每次生成的 boundary，由 `HTTPClient` 在发送时设置；
        // 这里返回 nil，避免静态值与实际 boundary 错位把请求发坏。
        case .multipart: return nil
        }
    }

    /// 编码后的请求体字符串（form 做 URL 编码）；空体返回 nil。
    ///
    /// multipart 不走这里：它含二进制文件内容，无法表示为 String ——
    /// 由 `HTTPClient.multipartBody` 直接产 `Data`。
    var encodedPayload: String? {
        switch kind {
        case .none, .multipart:
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

    /// 请求超时（秒）。
    ///
    /// 语义是 **空闲超时**，不是总时长：`URLRequest.timeoutInterval` 限的是「等待下一段响应数据」
    /// 的最长时间，每收到一段数据就重新计时。于是两类接口的表现完全不同：
    /// - **流式（SSE / chunked）**：只要相邻两块的间隔不超过该值就不会超时，整段生成可以远超它；
    /// - **非流式**：必须能等完从发出到首个字节的全部时间 —— 长耗时 LLM 生成正是卡在这里，
    ///   默认 30 秒对「先想 60 秒再一次性吐 JSON」的接口必然超时。
    var timeoutSeconds: Int = HTTPRequestModel.defaultTimeoutSeconds

    /// 超时取值区间（秒）。下限 1 秒，避免手输 0 或负数被 URLSession 当成「立即超时」；
    /// 上限 1 小时，足够覆盖最慢的非流式生成。
    static let minTimeoutSeconds = 1
    static let maxTimeoutSeconds = 3600
    static let defaultTimeoutSeconds = 30

    /// 编辑器里的常用档位（秒）。
    static let timeoutPresets = [15, 30, 60, 120, 300]

    /// 落到 `URLRequest.timeoutInterval` 的实际秒数。
    ///
    /// 界面上是自由输入的文本框，越界值在这里统一收口 —— 否则一个手误的 `0`
    /// 会让请求「秒失败」，而现象是「网络请求失败」，完全看不出是自己填的超时。
    var effectiveTimeout: TimeInterval {
        TimeInterval(min(max(timeoutSeconds, Self.minTimeoutSeconds), Self.maxTimeoutSeconds))
    }

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

// MARK: - 兼容旧数据的解码

extension HTTPBodyModel {
    /// 自定义解码的理由与下方 `HTTPRequestModel.init(from:)` 相同：multipart 的两个数组是后补字段，
    /// 而合成的 `init(from:)` 缺键直接抛 `keyNotFound`，集合与历史读取都写成 `try?` ——
    /// 不兜底的话，升级后所有旧请求记录会**静默整条消失**。新字段一律 `decodeIfPresent` 回退默认值。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        formFields = try c.decode([HTTPKV].self, forKey: .formFields)
        multipartFields = try c.decodeIfPresent([HTTPKV].self, forKey: .multipartFields) ?? []
        multipartFiles = try c.decodeIfPresent([HTTPMultipartFile].self, forKey: .multipartFiles) ?? []
    }
}

extension HTTPRequestModel {
    /// 自定义解码（放在扩展里，保留编译器合成的逐成员初始化器，与 `SSHProfile` 同款处理）。
    ///
    /// 起因：`timeoutSeconds` 是后补字段，而请求模型会被 JSON 编码进 SQLite ——
    /// 集合存 `http_requests.request_json`（`HTTPCollectionStore`），
    /// 历史存 `http_history` 的请求 blob（`HTTPHistoryStore`），会话快照里也有一份。
    ///
    /// 合成的 `init(from:)` **不会**回退到属性默认值：缺键直接抛 `keyNotFound`，
    /// 而集合与历史两处读取都写成 `try?` —— 一旦漏掉这里，升级后旧集合会**静默变空**、
    /// 旧历史整条消失，且没有任何报错，排查起来极其费劲。故新字段一律 `decodeIfPresent` 兜底。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decode(String.self, forKey: .method)
        urlString = try c.decode(String.self, forKey: .urlString)
        params = try c.decode([HTTPKV].self, forKey: .params)
        headers = try c.decode([HTTPKV].self, forKey: .headers)
        body = try c.decode(HTTPBodyModel.self, forKey: .body)
        auth = try c.decode(HTTPAuthModel.self, forKey: .auth)
        // 后补字段：旧记录没有这个键，缺失即回落到默认档。
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? Self.defaultTimeoutSeconds
    }
}
