//
//  GitRunner.swift
//  devkit
//
//  Git 子进程执行器：统一以 /usr/bin/git（及 /usr/bin/ssh-keygen）跑命令，捕获 stdout / stderr /
//  退出码，并支持逐行回调以驱动「输出控制台」实时刷新。沙盒已关（app-sandbox=false），可直接 spawn。
//
//  设计要点：
//  - 用 readabilityHandler 边读边累积，避免 readDataToEndOfFile 对两个管道顺序读取时缓冲写满死锁
//    （log / diff 输出可能很大）。
//  - 环境继承当前进程再叠加覆盖项（GIT_SSH_COMMAND 等），并确保 PATH 命中系统 git / ssh。
//

import Foundation

/// 一次子进程执行的聚合输出。
struct GitProcessOutput {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { exitCode == 0 }

    /// 失败时的可读信息：优先 stderr，退回退出码。
    var errorText: String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "命令退出码 \(exitCode)" : trimmed
    }
}

enum GitRunner {
    /// 系统 git 可执行文件路径。
    static let gitPath = "/usr/bin/git"
    /// 系统 ssh-keygen 路径。
    static let sshKeygenPath = "/usr/bin/ssh-keygen"

    /// 执行一条命令。
    /// - Parameters:
    ///   - executable: 绝对路径（如 `/usr/bin/git`）。
    ///   - arguments: 参数数组（不 shell 解释，直接 argv 传递，天然防注入）。
    ///   - workingDirectory: 工作目录（仓库路径）；nil 用当前目录。
    ///   - environment: 叠加到继承环境之上的覆盖项。
    ///   - onLine: 每读到一行 stdout/stderr 时在主 actor 回调（供实时控制台）。
    static func run(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String] = [:],
        onLine: (@MainActor (String) -> Void)? = nil
    ) async throws -> GitProcessOutput {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GitProcessOutput, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let wd = workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: wd)
            }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(env["PATH"] ?? "/usr/bin")"
            for (k, v) in environment { env[k] = v }
            // 关闭交互式提示：git 需要输入用户名/口令时直接失败而非挂起等待 tty。
            env["GIT_TERMINAL_PROMPT"] = "0"
            // 非交互：任何需编辑器的命令（commit/rebase --continue 等）不弹 $EDITOR，避免子进程挂死。
            env["GIT_EDITOR"] = "true"
            env["GIT_SEQUENCE_EDITOR"] = "true"
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // 累积与逐行切分在专用串行队列进行，保证顺序且无数据竞争。
            let collector = OutputCollector(onLine: onLine)
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { collector.append(data, isStderr: false) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { collector.append(data, isStderr: true) }
            }

            process.terminationHandler = { proc in
                // 收尾：flush 两个管道剩余数据，再回调完成。
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let out = collector.finalize()
                let result = GitProcessOutput(exitCode: proc.terminationStatus,
                                              stdout: out.stdout,
                                              stderr: out.stderr)
                cont.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: GitError.launchFailed(executable, error.localizedDescription))
            }
        }
    }

    /// git 便捷入口。
    static func git(_ arguments: [String],
                    at workingDirectory: String,
                    environment: [String: String] = [:],
                    onLine: (@MainActor (String) -> Void)? = nil) async throws -> GitProcessOutput {
        try await run(executable: gitPath, arguments: arguments,
                      workingDirectory: workingDirectory, environment: environment, onLine: onLine)
    }
}

/// 失败错误。
enum GitError: LocalizedError {
    case launchFailed(String, String)
    case failed(String)   // 命令非零退出，携带 errorText
    case notARepository(String)
    case missing(String)  // 缺少必要对象（如密钥私钥文件丢失）

    var errorDescription: String? {
        switch self {
        case .launchFailed(let exe, let m): return "无法启动 \(exe)：\(m)"
        case .failed(let m): return m
        case .notARepository(let p): return "不是有效的 Git 仓库：\(p)"
        case .missing(let m): return m
        }
    }
}

/// 线程安全的输出累积 + 逐行分发。
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutPartial = ""
    private var stderrPartial = ""
    private let onLine: (@MainActor (String) -> Void)?

    init(onLine: (@MainActor (String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data, isStderr: Bool) {
        lock.lock()
        if isStderr { stderrData.append(data) } else { stdoutData.append(data) }
        lock.unlock()
        guard let onLine else { return }
        // 逐行分发（保留未完成的尾行到下次）。
        guard let text = String(data: data, encoding: .utf8) else { return }
        var buffer = isStderr ? stderrPartial : stdoutPartial
        buffer += text
        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)
        if let last = lines.last, !last.isEmpty {
            // 最后一段可能不完整，留到下次。
            if isStderr { stderrPartial = String(last) } else { stdoutPartial = String(last) }
            let complete = lines.dropLast()
            for line in complete where !line.isEmpty { emit(line, onLine) }
        } else {
            if isStderr { stderrPartial = "" } else { stdoutPartial = "" }
            for line in lines where !line.isEmpty { emit(line, onLine) }
        }
    }

    private func emit(_ line: Substring, _ onLine: @escaping @MainActor (String) -> Void) {
        let s = String(line)
        Task { @MainActor in onLine(s) }
    }

    func finalize() -> (stdout: String, stderr: String) {
        lock.lock(); defer { lock.unlock() }
        return (String(data: stdoutData, encoding: .utf8) ?? "",
                String(data: stderrData, encoding: .utf8) ?? "")
    }
}
