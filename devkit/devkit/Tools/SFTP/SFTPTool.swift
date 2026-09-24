//
//  SFTPTool.swift
//  devkit
//
//  M6：SFTP 双向传输工具（视图模型）。一个标签 = 左右两个远端面板：
//  各自选择一条 SSH 连接（复用 SSH 终端的连接配置库）并浏览目录，
//  中间按钮把选中项（文件/文件夹，支持多选）按方向传到对端当前目录。
//  传输经本地临时文件中转（源下载 → 目标上传），递归复制整个文件夹树。
//

import Foundation
import SwiftUI

@Observable
final class SFTPTool: DevkitTool {
    static let descriptor = ToolDescriptor(
        id: "tool.sftp",
        title: "SFTP 传输",
        symbolName: "arrow.left.arrow.right.square",
        category: .terminal,
        subtitle: "左右两区各连一台主机，多选文件或文件夹互传。",
        allowsMultipleInstances: true,
        supportsWindowDetach: true
    )

    var descriptor: ToolDescriptor { Self.descriptor }

    enum Side: String {
        case left, right
    }

    // MARK: - 两侧状态

    let left = SFTPSideState(side: .left)
    let right = SFTPSideState(side: .right)

    func side(_ side: Side) -> SFTPSideState {
        side == .left ? left : right
    }

    // MARK: - 传输状态

    struct TransferState {
        var sourceLabel: String
        var targetLabel: String
        var currentItem: String
        var completedFiles: Int
        var totalFiles: Int
        var bytesDone: UInt64      // 整体已传字节
        var bytesTotal: UInt64     // 整体总字节（统计阶段为 0）
        var isEnumerating: Bool    // 正在递归统计文件清单
        var error: String?
    }

    /// 一个待传文件（枚举阶段收集）。Sendable：仅含值类型。
    struct TransferFile: Sendable {
        let name: String
        let sourcePath: String
        let targetPath: String
        let size: UInt64
    }

    /// 小文件阈值：小于此值的文件并发传输，用并发掩盖每文件的往返延迟。
    static let smallFileThreshold: UInt64 = 500 * 1024
    /// 小文件并发上限（× 每文件内部读窗口，控制在服务端在途请求上限之下）。
    private static let smallFileConcurrency = 4

    /// 进行中的传输；nil = 空闲。
    private(set) var transfer: TransferState?
    private var transferTask: Task<Void, Never>?

    var isTransferring: Bool { transfer != nil }

    var canTransferFromLeft: Bool { left.isConnected && right.isConnected && !left.selection.isEmpty && !isTransferring }
    var canTransferFromRight: Bool { left.isConnected && right.isConnected && !right.selection.isEmpty && !isTransferring }

    // MARK: - DevkitTool

    var dynamicTabTitle: String? {
        switch (left.displayName, right.displayName) {
        case let (l?, r?): return "\(l) ⇄ \(r)"
        case (let l?, nil): return "SFTP: \(l)"
        case (nil, let r?): return "SFTP: \(r)"
        default: return nil
        }
    }

    var hasUnsavedContent: Bool { false }

    @MainActor func makeView() -> AnyView {
        AnyView(SFTPToolView(tool: self))
    }

    /// 标签关闭：断开两侧连接（各自关闭通道并关停事件循环组）。
    @MainActor func teardownOnTabClose() {
        transferTask?.cancel()
        transferTask = nil
        left.disconnect()
        right.disconnect()
    }

    // MARK: - 传输

    /// 把源侧选中的条目按方向传到目标侧当前目录。
    @MainActor
    func transfer(from source: Side, to target: Side) {
        guard !isTransferring else { return }
        let sourceSide = side(source)
        let targetSide = side(target)
        guard sourceSide.isConnected, targetSide.isConnected, !sourceSide.selection.isEmpty else { return }

        let selected = sourceSide.entries.filter { sourceSide.selection.contains($0.name) }
        guard !selected.isEmpty else { return }

        transfer = TransferState(sourceLabel: sourceSide.label,
                                 targetLabel: targetSide.label,
                                 currentItem: "正在统计文件…",
                                 completedFiles: 0,
                                 totalFiles: 0,
                                 bytesDone: 0,
                                 bytesTotal: 0,
                                 isEnumerating: true,
                                 error: nil)
        transferTask = Task { [weak self] in
            await self?.runTransfer(selected: selected,
                                    source: sourceSide,
                                    target: targetSide)
        }
    }

    func cancelTransfer() {
        transferTask?.cancel()
    }

    /// 传输完成/失败后手动收起横幅。
    func dismissTransfer() {
        guard transfer?.error != nil else { return }
        transfer = nil
    }

    @MainActor
    private func runTransfer(selected: [SFTPEntry], source: SFTPSideState, target: SFTPSideState) async {
        guard let sourceBackend = source.backend, let targetBackend = target.backend else {
            transferTask = nil
            transfer = nil
            return
        }
        let sourceBase = source.path
        let targetBase = target.path

        // 1) 递归枚举：收集全部文件（含大小）并在目标侧预建目录，用于整体总量与目录结构。
        var files: [TransferFile] = []
        do {
            for entry in selected {
                try Task.checkCancellation()
                let s = Self.joinPath(sourceBase, entry.name)
                let d = Self.joinPath(targetBase, entry.name)
                if entry.isDirectory {
                    try? await targetBackend.makeDirectory(d)
                    try await enumerate(source: sourceBackend, target: targetBackend,
                                        srcDir: s, dstDir: d, into: &files)
                } else {
                    files.append(TransferFile(name: entry.name, sourcePath: s, targetPath: d,
                                              size: entry.attrs.size ?? 0))
                }
            }
        } catch is CancellationError {
            // 统计阶段取消：直接收尾（无错误）。
        } catch {
            finishTransfer(error: error.localizedDescription, cancelled: false, source: source, target: target)
            return
        }

        let totalBytes = files.reduce(UInt64(0)) { $0 &+ $1.size }
        let box = ProgressBox(files: files) { [weak self] done, doneFiles, name in
            self?.transfer?.bytesDone = done
            self?.transfer?.completedFiles = doneFiles
            self?.transfer?.currentItem = name
        }
        transfer?.isEnumerating = false
        transfer?.totalFiles = files.count
        transfer?.bytesTotal = totalBytes

        let largeIdx = files.indices.filter { files[$0].size >= Self.smallFileThreshold }
        let smallIdx = files.indices.filter { files[$0].size < Self.smallFileThreshold }

        var firstError: String?

        // 2) 大文件顺序（各自内部已读写流水线，再跨文件并行易撞服务端在途上限）。
        for idx in largeIdx {
            if Task.isCancelled { break }
            do { try await Self.transferOneFile(index: idx, files: files, box: box, source: sourceBackend, target: targetBackend) }
            catch is CancellationError { break }
            catch { firstError = "\(files[idx].name)：\(error.localizedDescription)"; break }
        }

        // 3) 小文件并发（有界），掩盖每文件往返延迟。
        if firstError == nil, !smallIdx.isEmpty, !Task.isCancelled {
            do { try await Self.runSmallFilesConcurrently(indices: smallIdx, limit: Self.smallFileConcurrency, files: files, box: box, source: sourceBackend, target: targetBackend) }
            catch is CancellationError { }
            catch { firstError = error.localizedDescription }
        }

        finishTransfer(error: firstError, cancelled: Task.isCancelled, source: source, target: target)
    }

    /// 递归枚举目录：目标侧建目录 + 收集文件项（含大小）。
    @MainActor
    private func enumerate(source: any SFTPBackend, target: any SFTPBackend,
                           srcDir: String, dstDir: String, into files: inout [TransferFile]) async throws {
        let children = try await source.listDirectory(srcDir)
        for child in children {
            try Task.checkCancellation()
            let s = Self.joinPath(srcDir, child.name)
            let d = Self.joinPath(dstDir, child.name)
            if child.isDirectory {
                try? await target.makeDirectory(d)
                try await enumerate(source: source, target: target, srcDir: s, dstDir: d, into: &files)
            } else {
                files.append(TransferFile(name: child.name, sourcePath: s, targetPath: d, size: child.attrs.size ?? 0))
            }
        }
    }

    /// 传输单个文件：源下载→临时文件→目标上传；两腿合计为整体贡献的 0~100%。
    private static func transferOneFile(index: Int, files: [TransferFile], box: ProgressBox,
                                        source: any SFTPBackend, target: any SFTPBackend) async throws {
        let f = files[index]
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devkit-sftp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await source.downloadFile(f.sourcePath, to: tempURL) { done, total in
            box.setProgress(index: index, fraction: legFraction(done: done, total: total, size: f.size) * 0.5, name: f.name)
        }
        try await target.uploadFile(from: tempURL, to: f.targetPath) { done, total in
            box.setProgress(index: index, fraction: 0.5 + legFraction(done: done, total: total, size: f.size) * 0.5, name: f.name)
        }
        box.fileFinished(index: index)
    }

    /// 有界并发跑小文件；首个错误后取消其余并上抛。
    private static func runSmallFilesConcurrently(indices: [Int], limit: Int, files: [TransferFile], box: ProgressBox,
                                                  source: any SFTPBackend, target: any SFTPBackend) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = indices.makeIterator()
            var inFlight = 0
            var firstError: Error?

            func feed() {
                while inFlight < limit, firstError == nil, let idx = iterator.next() {
                    inFlight += 1
                    group.addTask {
                        try await transferOneFile(index: idx, files: files, box: box, source: source, target: target)
                    }
                }
            }

            feed()
            while inFlight > 0 {
                do {
                    try await group.next()
                    inFlight -= 1
                    feed()
                } catch {
                    if firstError == nil { firstError = error }
                    inFlight -= 1
                    group.cancelAll()
                    do { for try await _ in group { } } catch { }
                    break
                }
            }
            if let error = firstError { throw error }
        }
    }

    /// 单腿完成度：优先用应答给出的 total，其次用枚举阶段得到的 size 兜底。
    private static func legFraction(done: UInt64, total: UInt64?, size: UInt64) -> Double {
        let denom = total ?? (size > 0 ? size : nil)
        guard let d = denom, d > 0 else { return done > 0 ? 1 : 0 }
        return min(1, Double(done) / Double(d))
    }

    /// 收尾：刷新两侧、清选中；失败/取消时保留一条横幅供用户关闭。
    @MainActor
    private func finishTransfer(error: String?, cancelled: Bool, source: SFTPSideState, target: SFTPSideState) {
        transferTask = nil
        let finished = transfer
        transfer = nil

        Task { await source.refresh(); await target.refresh() }
        source.selection.removeAll()
        target.selection.removeAll()

        if let error, var summary = finished {
            summary.error = cancelled
                ? "已取消（\(summary.completedFiles)/\(summary.totalFiles) 项）"
                : "传输失败：\(error)"
            summary.isEnumerating = false
            transfer = summary
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if self?.transfer?.error == summary.error { self?.transfer = nil }
            }
        }
    }

    /// 整体进度记账：每个文件按下载(0~50%)+上传(50~100%) 计入总量；累加/去重都只在主线程发生。
    private final class ProgressBox: @unchecked Sendable {
        let files: [TransferFile]
        private var contributions: [UInt64]
        private var completedBytes: UInt64 = 0
        private var completedFiles: Int = 0
        private let onUpdate: (_ done: UInt64, _ doneFiles: Int, _ name: String) -> Void

        init(files: [TransferFile], onUpdate: @escaping (_ done: UInt64, _ doneFiles: Int, _ name: String) -> Void) {
            self.files = files
            self.contributions = Array(repeating: 0, count: files.count)
            self.onUpdate = onUpdate
        }

        func setProgress(index: Int, fraction: Double, name: String) {
            guard index < contributions.count else { return }
            let clamped = min(max(fraction, 0), 1)
            let target = UInt64(Double(files[index].size) * clamped)
            let old = contributions[index]
            if target > old { completedBytes = completedBytes &+ (target &- old) }
            contributions[index] = max(old, target)
            onUpdate(completedBytes, completedFiles, name)
        }

        func fileFinished(index: Int) {
            setProgress(index: index, fraction: 1, name: index < files.count ? files[index].name : "")
            completedFiles += 1
            onUpdate(completedBytes, completedFiles, index < files.count ? files[index].name : "")
        }
    }

    // MARK: - 路径工具

    static func joinPath(_ base: String, _ name: String) -> String {
        guard !name.isEmpty else { return base }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }
}

// MARK: - 单侧状态

@MainActor
@Observable
final class SFTPSideState {
    let side: SFTPTool.Side

    private(set) var backend: (any SFTPBackend)?
    private(set) var profile: SSHProfile?
    private(set) var isLocal = false
    private(set) var path = ""
    private(set) var entries: [SFTPEntry] = []
    /// 预排序的展示列表：仅在目录内容变化时重算一次，
    /// 避免每次点击（selection 变更触发视图刷新）都重新排序整个列表——那是“选择文件夹卡顿”的主因。
    private(set) var sortedEntries: [SFTPEntry] = []
    @ObservationIgnored private var entryNames = Set<String>()
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// 当前多选的条目名集合。
    var selection = Set<String>()

    init(side: SFTPTool.Side) {
        self.side = side
    }

    var isConnected: Bool { backend?.isConnected ?? false }

    var state: SFTPBackendState { backend?.state ?? .idle }

    var label: String {
        if isLocal { return "本机" }
        guard let profile else { return side == .left ? "左侧" : "右侧" }
        return "\(profile.username)@\(profile.host)"
    }

    /// 标签标题用的简称：本地 = "本机"，远端 = host。
    var displayName: String? {
        if isLocal { return "本机" }
        return profile?.host
    }

    /// 统一入口：同时刷新原始列表、名字集与预排序列表，保证三者一致。
    private func applyEntries(_ new: [SFTPEntry]) {
        entries = new
        entryNames = Set(new.map(\.name))
        sortedEntries = new.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// 连接远端：完成后解析初始目录并列出。
    func connect(to profile: SSHProfile) async {
        errorMessage = nil
        isLocal = false
        self.profile = profile
        let conn = SFTPConnection()
        backend = conn
        await conn.connect(profile: profile)
        if let failure = connectionFailure {
            errorMessage = failure
            return
        }
        do {
            path = try await conn.resolvePath(".")
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 连接本地：直接浏览这台 Mac 的文件系统，默认进入用户主目录。
    func connectLocal() async {
        errorMessage = nil
        isLocal = true
        profile = nil
        let local = LocalSFTPBackend()
        backend = local
        await local.connect()
        do {
            path = try await local.resolvePath(".")
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        backend?.disconnect()
        backend = nil
        profile = nil
        isLocal = false
        applyEntries([])
        selection.removeAll()
        path = ""
        errorMessage = nil
    }

    var connectionFailure: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// 列出当前目录。
    func refresh() async {
        guard isConnected, !path.isEmpty, let backend else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let new = try await backend.listDirectory(path)
            applyEntries(new)
            errorMessage = nil
            selection = selection.filter { entryNames.contains($0) }
        } catch is CancellationError {
            // 保持原列表。
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 跳转到指定路径（路径栏回车）。正在加载时忽略，避免连点把请求堆在串行管道里。
    func navigate(to newPath: String) async {
        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isConnected, !isLoading, let backend else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let new = try await backend.listDirectory(trimmed)
            path = trimmed
            applyEntries(new)
            selection.removeAll()
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = "无法进入 \(trimmed)：\(error.localizedDescription)"
        }
    }

    /// 进入子目录。
    func enter(_ entry: SFTPEntry) async {
        guard entry.isDirectory else { return }
        await navigate(to: SFTPTool.joinPath(path, entry.name))
    }

    /// 行点击的选中变更：普通点击单选替换；⌘ 点击切换该项（多选）。
    func applySelection(name: String, additive: Bool) {
        if additive {
            if selection.contains(name) { selection.remove(name) } else { selection.insert(name) }
        } else {
            selection = [name]
        }
    }

    /// 返回上级；已在根时停留原地。
    func goUp() async {
        guard path != "/" else { return }
        var base = path
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        let parent = (base as NSString).deletingLastPathComponent
        await navigate(to: parent.isEmpty ? "/" : parent)
    }

    /// 新建文件夹。
    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let backend else { return }
        do {
            try await backend.makeDirectory(SFTPTool.joinPath(path, trimmed))
            await refresh()
        } catch {
            errorMessage = "新建文件夹失败：\(error.localizedDescription)"
        }
    }

    /// 删除选中项。目录会先递归清空子项再 RMDIR（远端 RMDIR 只能删空目录，
    /// 直接删非空目录服务端会返回 Failure）。
    func deleteSelection() async {
        let names = selection
        guard !names.isEmpty, let backend else { return }
        isLoading = true
        defer { isLoading = false }
        var failures: [String] = []
        for name in names {
            guard let entry = entries.first(where: { $0.name == name }) else { continue }
            do {
                try await deleteRecursively(backend,
                                            path: SFTPTool.joinPath(path, name),
                                            isDirectory: entry.isDirectory)
            } catch {
                failures.append("\(name)：\(error.localizedDescription)")
            }
        }
        await refresh()
        selection.removeAll()
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "；")
        }
    }

    /// 递归删除：目录先删空子项再 removeDirectory；文件直接 removeFile。
    private func deleteRecursively(_ backend: any SFTPBackend,
                                   path: String,
                                   isDirectory: Bool) async throws {
        guard isDirectory else {
            try await backend.removeFile(path)
            return
        }
        // 先尽力清空子项（列不出来则交给下面 removeDirectory 报真实错误）。
        if let children = try? await backend.listDirectory(path) {
            for child in children {
                try await deleteRecursively(backend,
                                            path: SFTPTool.joinPath(path, child.name),
                                            isDirectory: child.isDirectory)
            }
        }
        try await backend.removeDirectory(path)
    }
}
