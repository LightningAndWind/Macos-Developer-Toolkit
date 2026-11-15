//
//  HTTPComponents.swift
//  devkit
//
//  M2：HTTP 工具复用的展示组件与格式化工具。
//

import AppKit
import SwiftUI

/// 展示层格式化与配色。
enum HTTPDisplay {
    /// 字节数转可读字符串（B / KB / MB）。
    ///
    /// 必须带上 `.useBytes`：`allowedUnits` 里只有 KB 起步时，1 KB 以下一律四舍五入成
    /// 「0 KB」—— 一个 673 字节的响应会显示成 0 KB，用户会以为响应体是空的。
    /// 口径是 `countStyle: .file`，即**十进制**（1000 进制）；
    /// 因此响应体上限之类的常量要用 10_000_000 而不是 10 * 1_048_576，
    /// 否则界面上会显示成「10.5 MB」，与文档对不上。
    static func size(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// 耗时格式化：< 1000ms 显示 ms，否则显示 s。
    static func duration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.2f s", Double(ms) / 1000)
    }

    /// 超时秒数的紧凑文案：整分钟用 m、整小时用 h，其余用 s（30 → `30s`，120 → `2m`，3600 → `1h`）。
    ///
    /// 先夹到合法区间再格式化：文本框允许自由输入，`5000` 这类越界值会被
    /// `effectiveTimeout` 收口成上限，标签若照原样显示就会出现「界面写着 5000，实际按 1 小时跑」的错位。
    static func timeoutLabel(_ seconds: Int) -> String {
        let clamped = min(max(seconds, HTTPRequestModel.minTimeoutSeconds),
                          HTTPRequestModel.maxTimeoutSeconds)
        if clamped % 3600 == 0 { return "\(clamped / 3600)h" }
        if clamped % 60 == 0 { return "\(clamped / 60)m" }
        return "\(clamped)s"
    }

    /// 请求方法配色：方法选择器与历史记录共用，保证同一方法全局同色。
    static func color(forMethod method: String) -> Color {
        switch method.uppercased() {
        case "GET": return .green
        case "POST": return .blue
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        case "HEAD": return .purple
        case "OPTIONS": return .teal
        default: return .secondary
        }
    }

    /// 状态码分类对应颜色。
    static func color(for category: HTTPResponseModel.StatusCategory) -> Color {
        switch category {
        case .informational: return .gray
        case .success: return .green
        case .redirection: return .blue
        case .clientError: return .orange
        case .serverError: return .red
        case .transportError, .unknown: return .secondary
        }
    }

    // MARK: 历史时间：显示“请求发生的时刻”（静态绝对时间，不实时跳动）。

    private static let dayTimeFormatter: DateFormatter = fixedFormat("HH:mm")
    private static let monthDayFormatter: DateFormatter = fixedFormat("MM-dd HH:mm")
    private static let fullFormatter: DateFormatter = fixedFormat("yyyy-MM-dd HH:mm")
    private static let fullSecondsFormatter: DateFormatter = fixedFormat("yyyy-MM-dd HH:mm:ss")

    private static func fixedFormat(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }

    /// 今天显时分，今年显月日时分，否则显完整日期；均为静态文本，不会随时间刷新。
    static func historyTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: .now) { return dayTimeFormatter.string(from: date) }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) { return monthDayFormatter.string(from: date) }
        return fullFormatter.string(from: date)
    }

    /// 详情弹窗用的完整时间戳（年月日时分秒）。
    static func fullTimestamp(_ date: Date) -> String {
        fullSecondsFormatter.string(from: date)
    }
}

/// 键值对编辑器：Params / Headers / Form 复用；可选每行启用开关。
struct HTTPKVEditor: View {
    @Binding var items: [HTTPKV]
    var keyPlaceholder: String = "键"
    var valuePlaceholder: String = "值"
    var showsEnabledToggle: Bool = false
    var footerActions: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Text("暂无条目")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach($items) { $item in
                    HStack(spacing: 8) {
                        if showsEnabledToggle {
                            Toggle("", isOn: $item.enabled)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .frame(width: 18)
                        }
                        // 占位符经 String 参数传入，TextField 走 StringProtocol 通道不查表，需 L()。
                        TextField(L(keyPlaceholder), text: $item.key)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .frame(width: 150)
                        TextField(L(valuePlaceholder), text: $item.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity)
                        Button {
                            items.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    items.append(HTTPKV())
                } label: {
                    Label("添加", systemImage: "plus")
                }
                footerActions
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
    }
}

/// multipart 文件条目编辑器：每行 [启用开关] [字段名] [选择文件] [MIME] [删除]，
/// 选中文件后附一行「上传文件名 + 完整路径」。与 `HTTPKVEditor` 同风格。
///
/// MIME / 上传文件名**留空即自动**：MIME 按扩展名推断（占位文本实时显示推导值），
/// 文件名取路径末段。显式填了则视为有意覆盖，重新选文件不会改写它们。
struct MultipartFileEditor: View {
    @Binding var files: [HTTPMultipartFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if files.isEmpty {
                Text("暂无文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach($files) { $file in
                    fileRow($file)
                }
            }

            HStack(spacing: 8) {
                Button {
                    files.append(HTTPMultipartFile())
                } label: {
                    Label("添加文件", systemImage: "plus")
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
    }

    private func fileRow(_ file: Binding<HTTPMultipartFile>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: file.enabled)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: 18)
                TextField("字段名", text: file.fieldName)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 110)
                Button {
                    pickFile(into: file)
                } label: {
                    Label(
                        // 三目结果是 String 变量通道，占位文案要显式 L()；文件名本身不翻。
                        file.wrappedValue.effectiveFileName.isEmpty ? L("选择文件") : file.wrappedValue.effectiveFileName,
                        systemImage: file.wrappedValue.filePath.isEmpty ? "folder" : "doc"
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // 固定中等宽度：撑满整行在宽窗口下过于巨大，且选中文件后行内控件会错位。
                    .frame(width: 220)
                }
                .buttonStyle(.bordered)
                // 悬停可见完整路径：行内只显示文件名，重放历史时要能核对选的是哪个文件。
                .help(file.wrappedValue.filePath)
                TextField("MIME", text: file.mimeType, prompt: Text(file.wrappedValue.effectiveMimeType))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 150)
                Button {
                    files.removeAll { $0.id == file.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            if !file.wrappedValue.filePath.isEmpty {
                HStack(spacing: 8) {
                    Text("上传名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("上传文件名", text: file.fileName,
                              prompt: Text((file.wrappedValue.filePath as NSString).lastPathComponent))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: 180)
                    Text(file.wrappedValue.filePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 选文件；面板用法与 `SSHProfileEditorView.pickKey` 一致（`runModal`）。
    private func pickFile(into file: Binding<HTTPMultipartFile>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = L("选择文件")
        // 二次选择时默认停在上次目录
        if !file.wrappedValue.filePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (file.wrappedValue.filePath as NSString).deletingLastPathComponent,
                                     isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        file.wrappedValue.filePath = url.path
    }
}

/// 一个带标题的分区容器。
struct HTTPSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
