//
//  CurlExporter.swift
//  devkit
//
//  M2：把请求模型导出为可直接粘贴到终端的 cURL 命令（"复制为 cURL"）。
//  从 cURL 导入留待 M6。
//

import Foundation

enum CurlExporter {
    /// 生成 cURL 命令字符串。
    static func curlCommand(from request: HTTPRequestModel) -> String {
        var lines: [String] = ["curl"]

        let method = request.method.trimmingCharacters(in: .whitespaces).uppercased()
        // GET 是 cURL 默认，省略 -X 更贴近习惯；其余显式指定。
        if method != "GET" {
            lines.append("  -X \(method)")
        }

        // Headers
        for header in request.enabledHeaders {
            lines.append("  -H \(quote("\(header.key): \(header.value)"))")
        }

        // Auth
        if let authHeader = request.auth.headerValue {
            lines.append("  -H \(quote("Authorization: \(authHeader)"))")
        }

        // Body
        if !request.body.isEmpty, let payload = request.body.encodedPayload {
            if let contentType = request.body.contentType {
                lines.append("  -H \(quote("Content-Type: \(contentType)"))")
            }
            lines.append("  --data \(quote(payload))")
        }

        // URL 放最后
        lines.append("  \(quote(request.appliedURLString))")

        return lines.joined(separator: " \\\n")
    }

    /// 用单引号包裹并对内部单引号做 shell 转义。
    private static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
