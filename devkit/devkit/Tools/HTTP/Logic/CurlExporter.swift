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
        let isMultipart = request.body.kind == .multipart && !request.body.isEmpty
        var lines: [String] = ["curl"]

        let method = request.method.trimmingCharacters(in: .whitespaces).uppercased()
        // GET 是 cURL 默认，省略 -X 更贴近习惯；其余显式指定。
        if method != "GET" {
            lines.append("  -X \(method)")
        }

        // Headers。multipart 时跳过用户手填的 Content-Type：`-F` 会自带带 boundary 的正确版本，
        // 手填的若盖在上面，边界对不上、发出的命令必坏 —— 与 HTTPClient.makeURLRequest 的覆盖逻辑同理。
        for header in request.enabledHeaders {
            if isMultipart, header.key.caseInsensitiveCompare("Content-Type") == .orderedSame { continue }
            lines.append("  -H \(quote("\(header.key): \(header.value)"))")
        }

        // Auth
        if let authHeader = request.auth.headerValue {
            lines.append("  -H \(quote("Authorization: \(authHeader)"))")
        }

        // Body
        if isMultipart {
            // 文本字段：-F 'k=v'；文件：-F 'field=@路径;type=mime'（filename 覆盖路径末段时显式带出）。
            for field in request.body.multipartFields where field.enabled && !field.key.isEmpty {
                lines.append("  -F \(quote("\(field.key)=\(field.value)"))")
            }
            for file in request.body.multipartFiles where file.isActive {
                var part = "\(file.fieldName)=@\(file.filePath);type=\(file.effectiveMimeType)"
                let pathLast = (file.filePath as NSString).lastPathComponent
                if !file.fileName.isEmpty && file.fileName != pathLast {
                    part += ";filename=\(file.fileName)"
                }
                lines.append("  -F \(quote(part))")
            }
        } else if !request.body.isEmpty, let payload = request.body.encodedPayload {
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
