//
//  LocalSFTPBackend.swift
//  devkit
//
//  M6：SFTP 一侧的「本地」数据源——直接浏览/读写这台 Mac 的文件系统。
//  与远端实现（SFTPConnection）满足同一 SFTPBackend 协议，因而可任意组合互传。
//  工程未开启 App Sandbox，直接用 FileManager 访问用户可读写的路径。
//

import Foundation

@MainActor
@Observable
final class LocalSFTPBackend: SFTPBackend {
    private(set) var state: SFTPBackendState = .idle

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// 计算机名，用于面板标题（例如「本机 · my-mac」）。不参与观察，用普通存储属性。
    @ObservationIgnored private let machineName = Host.current().localizedName ?? "本机"

    /// 本地流式复制的分块大小（1MB）。
    private static let copyChunkSize = 1_048_576

    // MARK: - 连接（本地即时可用）

    /// 打开本地：无握手，直接把状态置为已连接。
    func connect() async {
        state = .connecting
        // 让 UI 有机会呈现「连接中」，随后进入主目录。
        try? await Task.sleep(nanoseconds: 120_000_000)
        state = .connected(host: machineName)
    }

    func disconnect() {
        state = .disconnected
    }

    // MARK: - 目录与元数据

    func resolvePath(_ path: String) async throws -> String {
        expand(path)
    }

    func listDirectory(_ path: String) async throws -> [SFTPEntry] {
        let dir = expand(path)
        return try await Self.enumerateEntries(dir: dir)
    }

    /// 在后台队列枚举目录并逐项 stat：避免大目录阻塞主线程（表现为选择文件夹时卡顿）。
    private nonisolated static func enumerateEntries(dir: String) async throws -> [SFTPEntry] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[SFTPEntry], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                do {
                    let names = try fm.contentsOfDirectory(atPath: dir)
                    var entries: [SFTPEntry] = []
                    entries.reserveCapacity(names.count)
                    for name in names where name != "." && name != ".." {
                        let full = (dir as NSString).appendingPathComponent(name)
                        entries.append(SFTPEntry(name: name, longName: "",
                                                 attrs: attributes(forPath: full, fileManager: fm)))
                    }
                    cont.resume(returning: entries)
                } catch {
                    cont.resume(throwing: SFTPError.serverError(
                        code: 3, message: "无法读取 \(dir)：\(error.localizedDescription)"))
                }
            }
        }
    }

    func makeDirectory(_ path: String) async throws {
        do {
            try FileManager.default.createDirectory(atPath: expand(path),
                                                    withIntermediateDirectories: true)
        } catch {
            throw SFTPError.serverError(code: 4, message: error.localizedDescription)
        }
    }

    func removeFile(_ path: String) async throws {
        try remove(at: path)
    }

    func removeDirectory(_ path: String) async throws {
        try remove(at: path)
    }

    // MARK: - 文件传输

    func downloadFile(_ path: String,
                      to localURL: URL,
                      progress: ((UInt64, UInt64?) -> Void)?) async throws {
        try await streamCopy(from: expand(path), to: localURL.path, progress: progress)
    }

    func uploadFile(from localURL: URL,
                    to path: String,
                    progress: ((UInt64, UInt64?) -> Void)?) async throws {
        try await streamCopy(from: localURL.path, to: expand(path), progress: progress)
    }

    // MARK: - 私有

    private func remove(at path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: expand(path))
        } catch {
            throw SFTPError.serverError(code: 4, message: error.localizedDescription)
        }
    }

    /// 分块流式复制：每块后让出主线程刷新 UI，并回报按字节的进度。
    /// （本地侧不再是单发 copyItem：那样会阻塞主线程、且只能“一下跳完”没有进度。）
    private func streamCopy(from src: String, to dst: String,
                            progress: ((UInt64, UInt64?) -> Void)?) async throws {
        let fm = FileManager.default
        let total = ((try? fm.attributesOfItem(atPath: src)[.size]) as? NSNumber)?.uint64Value
        if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: dst) }
        fm.createFile(atPath: dst, contents: nil)
        let inHandle: FileHandle
        do { inHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: src)) }
        catch { throw SFTPError.serverError(code: 2, message: "无法读取 \(src)") }
        defer { try? inHandle.close() }
        let outHandle: FileHandle
        do { outHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: dst)) }
        catch { throw SFTPError.serverError(code: 3, message: "无法写入 \(dst)") }
        defer { try? outHandle.close() }

        var done: UInt64 = 0
        while let chunk = try inHandle.read(upToCount: Self.copyChunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            try outHandle.write(contentsOf: chunk)
            done &+= UInt64(chunk.count)
            progress?(done, total)
            await Task.yield() // 每块让出一次主线程，保证进度条/界面持续刷新
        }
        progress?(done, total)
    }

    /// 展开 ~ 与相对路径为绝对路径；空 / "." 归到用户主目录。
    private func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." {
            return NSHomeDirectory()
        }
        if trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") {
            return (NSHomeDirectory() as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("/") {
            return (trimmed as NSString).standardizingPath ?? trimmed
        }
        // 相对路径按主目录解析（远端语义下一般已是绝对路径，这里兜底）。
        return ((NSHomeDirectory() as NSString).appendingPathComponent(trimmed) as NSString).standardizingPath ?? trimmed
    }

    /// 把本地文件属性映射为 SFTP 条目属性（POSIX 权限位布局，供 isDirectory 判定）。
    private nonisolated static func attributes(forPath path: String, fileManager fm: FileManager) -> SFTPAttrs {
        let raw = try? fm.attributesOfItem(atPath: path)
        let type = raw?[.type] as? FileAttributeType
        let isDir = type == .typeDirectory
        let size = (raw?[.size] as? NSNumber)?.uint64Value
        let mtime = (raw?[.modificationDate] as? Date).map { UInt32(max(0, $0.timeIntervalSince1970)) }
        // 0o100000 = 常规文件，0o040000 = 目录（与 SFTPAttrs 的 typeMask 判定对齐）。
        let permissions: UInt32 = isDir ? 0o040000 : 0o100000
        return SFTPAttrs(size: size, permissions: permissions, mtime: mtime)
    }
}
