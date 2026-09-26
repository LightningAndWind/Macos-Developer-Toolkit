//
//  GitRepository.swift
//  devkit
//
//  对单个仓库的一层薄操作封装：每个方法 = 一条（或一小串）git 命令 + 输出解析。
//  远程操作自动带上仓库绑定密钥翻译出的 GIT_SSH_COMMAND（见 GitSSHBridge），实现按 key 认证 + 跨设备。
//  路径参数一律置于 `--` 之后按 argv 传递，不经 shell 解释，天然防命令注入。
//

import Foundation

@MainActor
struct GitRepository {
    let path: String
    let environment: [String: String]

    init(path: String, environment: [String: String] = [:]) {
        self.path = path
        self.environment = environment
    }

    /// 由登记的仓库解析：工作目录 + 绑定密钥对应的 SSH 环境。
    init(repo: GitRepo) {
        self.path = repo.path
        self.environment = GitSSHBridge.environment(keyID: repo.keyID)
    }

    // MARK: - 基础执行

    private func run(_ args: [String],
                     onLine: (@MainActor (String) -> Void)? = nil) async throws -> GitProcessOutput {
        try await GitRunner.git(args, at: path, environment: environment, onLine: onLine)
    }

    @discardableResult
    private func require(_ args: [String],
                         onLine: (@MainActor (String) -> Void)? = nil) async throws -> GitProcessOutput {
        let out = try await run(args, onLine: onLine)
        if !out.succeeded { throw GitError.failed(out.errorText) }
        return out
    }

    // MARK: - 只读

    static func isGitRepo(_ path: String) async -> Bool {
        guard let out = try? await GitRunner.git(["rev-parse", "--is-inside-work-tree"], at: path) else { return false }
        return out.succeeded && out.stdout.contains("true")
    }

    /// 工作区状态（分支 / ahead-behind / 变更条目 / 是否变基中）。
    func status() async throws -> GitStatus {
        let out = try await run(["status", "--porcelain=v1", "-b", "--untracked-files=all"])
        return Self.parseStatus(out.stdout, rebasing: Self.detectRebasing(at: path))
    }

    static func detectRebasing(at path: String) -> Bool {
        let gitDir = URL(fileURLWithPath: path).appendingPathComponent(".git", isDirectory: true)
        let fm = FileManager.default
        return fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path)
            || fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path)
    }

    /// 解析 `status --porcelain=v1 -b` 文本。
    static func parseStatus(_ text: String, rebasing: Bool) -> GitStatus {
        var branch = "—"
        var upstream: String?
        var ahead = 0, behind = 0
        var entries: [GitFileEntry] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                let header = String(line.dropFirst(3))
                let parts = header.components(separatedBy: "...")
                branch = parts[0].trimmingCharacters(in: .whitespaces)
                if parts.count > 1 {
                    let rest = parts[1]
                    upstream = rest.components(separatedBy: " ").first
                    ahead = Int(extractInt(from: rest, key: "ahead") ?? "") ?? 0
                    behind = Int(extractInt(from: rest, key: "behind") ?? "") ?? 0
                }
                continue
            }
            guard line.count >= 4 else { continue }
            let idx = line.index(line.startIndex, offsetBy: 2)
            let xy = String(line[..<idx])
            var body = String(line[idx...]).trimmingCharacters(in: .whitespaces)
            var from: String?
            if xy.hasPrefix("R") || xy.hasPrefix("C"), let arrow = body.range(of: " -> ") {
                from = String(body[..<arrow.lowerBound])
                body = String(body[arrow.upperBound...])
            }
            entries.append(GitFileEntry(xy: xy, path: body, fromPath: from))
        }
        return GitStatus(branch: branch, upstream: upstream, ahead: ahead, behind: behind,
                         entries: entries, isRebasing: rebasing)
    }

    private static func extractInt(from s: String, key: String) -> String? {
        guard let r = s.range(of: "\(key) ") else { return nil }
        let tail = s[r.upperBound...]
        let num = tail.prefix(while: { $0.isNumber })
        return num.isEmpty ? nil : String(num)
    }

    /// 分支列表（本地 + 远程）。
    func branches() async throws -> (local: [GitBranch], remote: [GitBranch]) {
        let current = try? await run(["symbolic-ref", "--short", "HEAD"])
        let currentName = current?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let localOut = try await run(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
        let remoteOut = try await run(["for-each-ref", "--format=%(refname:short)", "refs/remotes"])
        let local = localOut.stdout.split(separator: "\n").map {
            GitBranch(name: String($0), isCurrent: String($0) == currentName, isRemote: false)
        }
        // 去掉 origin/HEAD 这类符号引用行。
        let remote = remoteOut.stdout.split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasSuffix("/HEAD") }
            .map { GitBranch(name: $0, isCurrent: false, isRemote: true) }
        return (local, remote)
    }

    /// 提交列表的统一格式：字段用 \x1f 分隔，每条记录以 \x1e 结尾（供 parseCommits 可靠切分多条）。
    static let commitFormat = "%H%x1f%h%x1f%an%x1f%ar%x1f%D%x1f%s%x1e"

    /// 提交历史（分页）。
    func log(count: Int, skip: Int) async throws -> [GitCommit] {
        let out = try await run(["log", "--pretty=format:\(Self.commitFormat)",
                                 "-n", String(count), "--skip", String(skip)])
        return Self.parseCommits(out.stdout)
    }

    /// 待推送提交：有上游取 `@{u}..HEAD`；无上游取「HEAD 上不属于任何远程」的提交。
    func unpushedCommits() async throws -> [GitCommit] {
        var args = ["log", "--pretty=format:\(Self.commitFormat)"]
        if await hasUpstream() { args.append("@{u}..HEAD") }
        else { args.append(contentsOf: ["HEAD", "--not", "--remotes"]) }
        let out = try await run(args)
        return Self.parseCommits(out.stdout)
    }

    /// 解析上面格式的 git 输出为提交列表。
    static func parseCommits(_ text: String) -> [GitCommit] {
        text.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { raw in
            let record = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !record.isEmpty else { return nil }
            let f = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6 else { return nil }
            return GitCommit(hash: f[0], shortHash: f[1], author: f[2],
                             relativeDate: f[3], refs: f[4], subject: f[5])
        }
    }

    /// 远程列表。
    func remotes() async throws -> [GitRemote] {
        let out = try await run(["remote", "-v"])
        var dict: [String: GitRemote] = [:]
        for line in out.stdout.split(separator: "\n") {
            let cols = line.split(separator: "\t").map(String.init)
            guard cols.count == 2, cols[1].hasSuffix(")") else { continue }
            let name = cols[0]
            let urlKind = String(cols[1].dropLast())  // "<url> (fetch)"
            guard let space = urlKind.lastIndex(of: " ") else { continue }
            let url = String(urlKind[..<space])
            let isFetch = urlKind.hasSuffix("(fetch)")
            var remote = dict[name] ?? GitRemote(name: name, fetchURL: nil, pushURL: nil)
            if isFetch { remote.fetchURL = url } else { remote.pushURL = url }
            dict[name] = remote
        }
        return dict.values.sorted { $0.name < $1.name }
    }

    func stashList() async throws -> [GitStashEntry] {
        let out = try await run(["stash", "list", "--format=%gd%x1f%s"])
        return out.stdout.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 2 else { return nil }
            let digits = f[0].filter { $0.isNumber }
            guard let idx = Int(digits) else { return nil }
            return GitStashEntry(index: idx, message: f[1])
        }
    }

    func tags() async throws -> [GitTag] {
        let out = try await run(["tag", "-l"])
        return out.stdout.split(separator: "\n").map { GitTag(name: String($0)) }
    }

    // MARK: - 暂存 / 提交

    func stage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await require(["add", "--"] + paths)
    }
    func stageAll() async throws { try await require(["add", "-A"]) }
    func unstage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await require(["restore", "--staged", "--"] + paths)
    }
    func unstageAll() async throws { try await require(["restore", "--staged", "."]) }
    func discard(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await require(["restore", "--"] + paths)
    }

    func commit(message: String, amend: Bool = false, stageAll: Bool = false) async throws {
        var args = ["commit", "-m", message]
        if amend { args.append("--amend") }
        if stageAll { args.append("-a") }
        try await require(args)
    }

    // MARK: - 分支

    func checkout(branch: String) async throws { try await require(["checkout", branch]) }
    func createBranch(name: String, checkout: Bool) async throws {
        if checkout { try await require(["checkout", "-b", name]) }
        else { try await require(["branch", name]) }
    }
    func deleteBranch(name: String, force: Bool) async throws {
        try await require(["branch", force ? "-D" : "-d", name])
    }
    func merge(branch: String, onLine: (@MainActor (String) -> Void)? = nil) async throws {
        try await require(["merge", branch], onLine: onLine)
    }

    // MARK: - 远程（注入 GIT_SSH_COMMAND）

    func fetch(remote: String?, onLine: (@MainActor (String) -> Void)? = nil) async throws {
        if let remote { try await require(["fetch", remote], onLine: onLine) }
        else { try await require(["fetch", "--all"], onLine: onLine) }
    }
    func pull(onLine: (@MainActor (String) -> Void)? = nil) async throws {
        try await require(["pull"], onLine: onLine)
    }
    func push(remote: String? = nil, branch: String? = nil, setUpstream: Bool = false,
              onLine: (@MainActor (String) -> Void)? = nil) async throws {
        var args = ["push"]
        var remote = remote
        var branch = branch
        var upstream = setUpstream
        // 未显式指定远程/分支时：若当前分支还没有上游，自动 --set-upstream 到首选远程（优先 origin）。
        if remote == nil, branch == nil, !upstream {
            let current = try? await currentBranch()
            if let current, !current.isEmpty, !(await hasUpstream()) {
                upstream = true
                branch = current
                remote = await primaryRemote()
            }
        }
        if upstream { args.append("--set-upstream") }
        if let remote { args.append(remote) }
        if let branch { args.append(branch) }
        try await require(args, onLine: onLine)
    }

    /// 当前分支名；分离头指针时返回 nil。
    func currentBranch() async throws -> String? {
        let out = try await run(["branch", "--show-current"])
        let name = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// 当前分支是否已配置上游跟踪。
    func hasUpstream() async -> Bool {
        let out = try? await run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        return out?.succeeded ?? false
    }

    /// 首选远程：有 origin 用 origin，否则第一个远程；无远程返回 nil。
    private func primaryRemote() async -> String? {
        let out = try? await run(["remote"])
        let list = (out?.stdout ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return list.contains("origin") ? "origin" : list.first
    }

    /// 克隆（静态：目标目录尚未成为仓库，工作目录用父目录）。
    static func clone(url: String, into destinationParent: String, subdirectory: String?,
                      environment: [String: String],
                      onLine: (@MainActor (String) -> Void)?) async throws -> String {
        var args = ["clone", url]
        if let subdirectory { args.append(subdirectory) }
        let out = try await GitRunner.git(args, at: destinationParent,
                                          environment: environment, onLine: onLine)
        guard out.succeeded else { throw GitError.failed(out.errorText) }
        return URL(fileURLWithPath: destinationParent)
            .appendingPathComponent(subdirectory ?? Self.repoName(from: url), isDirectory: true).path
    }

    static func repoName(from url: String) -> String {
        let trimmed = url.hasSuffix(".git") ? String(url.dropLast(4)) : url
        return trimmed.split(separator: "/").last.map(String.init) ?? "repo"
    }

    // MARK: - Stash

    func stashPush(message: String?) async throws {
        if let message, !message.isEmpty { try await require(["stash", "push", "-m", message]) }
        else { try await require(["stash", "push"]) }
    }
    func stashPop(index: Int) async throws { try await require(["stash", "pop", "stash@{\(index)}"]) }
    func stashApply(index: Int) async throws { try await require(["stash", "apply", "stash@{\(index)}"]) }
    func stashDrop(index: Int) async throws { try await require(["stash", "drop", "stash@{\(index)}"]) }

    // MARK: - 高级：rebase / cherry-pick / reset / tag / 冲突

    func rebase(onto: String?, onLine: (@MainActor (String) -> Void)? = nil) async throws {
        if let onto { try await require(["rebase", onto], onLine: onLine) }
        else { try await require(["rebase"], onLine: onLine) }
    }
    func rebaseContinue() async throws { try await require(["rebase", "--continue"]) }
    func rebaseAbort() async throws { try await require(["rebase", "--abort"]) }
    func rebaseSkip() async throws { try await require(["rebase", "--skip"]) }

    func cherryPick(hash: String) async throws { try await require(["cherry-pick", hash]) }

    enum ResetMode: String { case soft, mixed, hard }
    func reset(mode: ResetMode, to: String) async throws {
        try await require(["reset", "--\(mode.rawValue)", to])
    }

    func createTag(name: String) async throws { try await require(["tag", name]) }
    func deleteTag(name: String) async throws { try await require(["tag", "-d", name]) }

    /// 冲突解决：选边（ours/theirs）后标记已解决（git add）。
    enum ConflictSide { case ours, theirs }
    func resolveConflict(file: String, side: ConflictSide) async throws {
        try await require(["checkout", side == .ours ? "--ours" : "--theirs", "--", file])
        try await require(["add", "--", file])
    }
    func markResolved(file: String) async throws { try await require(["add", "--", file]) }

    // MARK: - 可选：把绑定密钥写入仓库 config（供脱离应用的终端使用）

    /// 写入 `core.sshCommand`（绝对路径，设备相关；换设备需重新写入）。
    func writeSSHCommandToConfig(_ sshCommand: String) async throws {
        try await require(["config", "core.sshCommand", sshCommand])
    }
}
