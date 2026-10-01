//
//  GitTool.swift
//  devkit
//
//  Git 管理工具（视图模型）。一个标签 = 一个当前仓库视图：左侧仓库集合树，右侧分区
//  （变更 / 分支 / 历史 / Stash / 远程）。所有 git 操作经 GitRepository 执行，远程操作按仓库
//  绑定的密钥注入 GIT_SSH_COMMAND。新标签进入「选择器」（GitStartupChooser）。
//
//  编排约定：每个动作 = isBusy 置位 → 执行 → 失败写 errorMessage / 成功刷新；流式动作（clone/fetch/
//  pull/push/merge/rebase）把逐行输出汇入内置控制台（consoleLines），供 GitOutputConsoleView 实时展示。
//

import SwiftUI

@Observable
final class GitTool: DevkitTool {
    static let descriptor = ToolDescriptor(
        id: "tool.git",
        title: "Git 管理",
        symbolName: "arrow.triangle.branch",
        category: .utility,
        subtitle: "仓库按文件夹归类登记，可绑定 SSH 密钥并按其执行 git 操作，支持跨设备复用密钥。",
        allowsMultipleInstances: true,
        supportsWindowDetach: true
    )

    var descriptor: ToolDescriptor { Self.descriptor }

    /// 右侧分区（仓库管理 / 远程操作 / 密钥绑定已移至设置页与顶部菜单）。
    enum Section: String, CaseIterable, Identifiable, Codable {
        case changes = "变更"
        case branches = "分支"
        case log = "历史"
        case stash = "Stash"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .changes: return "doc.text"
            case .branches: return "arrow.triangle.branch"
            case .log: return "clock.arrow.circlepath"
            case .stash: return "tray.and.arrow.down"
            }
        }
    }

    // MARK: - 选中仓库与数据

    private(set) var selectedRepo: GitRepo?
    var section: Section = .changes

    private(set) var status: GitStatus = .empty
    private(set) var localBranches: [GitBranch] = []
    private(set) var remoteBranches: [GitBranch] = []
    private(set) var commits: [GitCommit] = []
    private(set) var remotes: [GitRemote] = []
    private(set) var stashes: [GitStashEntry] = []
    private(set) var tags: [GitTag] = []
    /// 当前分支待推送的提交（驱动「未推送」分组与推送按钮可用性）。
    private(set) var unpushedCommits: [GitCommit] = []

    // MARK: - 工作区文件差异 / 冲突预览

    /// 当前选中查看差异的文件路径（nil = 未选中，不展示检查器）。
    private(set) var selectedFilePath: String?
    /// 选中文件的加载状态。
    private(set) var isDiffLoading = false
    private(set) var fileDiff: GitFileDiff?
    /// 冲突文件的工作区内容（含标记行）与解析出的冲突块。
    private(set) var conflictLines: [String] = []
    private(set) var conflictBlocks: [GitConflictBlock] = []
    /// 加载令牌：快速切换文件时作废旧加载的结果。
    private var diffLoadToken = UUID()

    /// 选中文件并加载其差异 / 冲突内容。
    func selectFileForDiff(_ entry: GitFileEntry) async {
        selectedFilePath = entry.path
        await loadFileDiff(entry)
    }

    func clearFileSelection() {
        selectedFilePath = nil
        fileDiff = nil
        conflictLines = []
        conflictBlocks = []
    }

    /// 重新加载当前选中文件（外部动作改变内容后调用）。
    func reloadSelectedFile() async {
        guard let entry = status.entries.first(where: { $0.path == selectedFilePath }) else { return }
        await loadFileDiff(entry)
    }

    private func loadFileDiff(_ entry: GitFileEntry) async {
        guard let git = repository() else { return }
        let token = UUID()
        diffLoadToken = token
        isDiffLoading = true
        defer { if diffLoadToken == token { isDiffLoading = false } }
        fileDiff = await git.fileDiff(entry: entry)
        if entry.conflicted {
            let parsed = try? await git.conflictBlocks(file: entry.path)
            guard diffLoadToken == token else { return }
            conflictLines = parsed?.lines ?? []
            conflictBlocks = parsed?.blocks ?? []
        } else {
            conflictLines = []
            conflictBlocks = []
        }
    }

    /// 按块解决冲突（保留我方/对方）：回写文件后重读；若标记已全部消除则自动 `git add` 落定。
    func resolveConflictBlock(entry: GitFileEntry, blockIndex: Int, keepOurSide: Bool) async {
        await perform { git in
            try await git.resolveConflictBlock(file: entry.path, keepOurSide: keepOurSide, blockIndex: blockIndex)
            let (_, blocks) = try await git.conflictBlocks(file: entry.path)
            if blocks.isEmpty {
                try await git.markResolved(file: entry.path)
            }
        }
    }

    /// 是否有待推送内容（有未推送提交 → 可推送）。
    var hasUnpushed: Bool { !unpushedCommits.isEmpty }

    /// 工作区是否存在未解决的冲突文件（驱动横幅提示与失败分流）。
    var hasConflict: Bool { !status.conflicted.isEmpty }

    /// 已加载的历史条数（分页）。
    private var logLoaded = 0
    private static let logPageSize = 20

    // MARK: - 运行状态

    /// 有操作进行中（禁用按钮、显示进度）。
    private(set) var isBusy = false
    /// 「刷新工作区」按钮专属进行中（驱动该按钮转圈）。
    private(set) var isRefreshing = false
    /// 「拉取代码」按钮专属进行中（驱动该按钮转圈）。
    private(set) var isPulling = false
    /// 一次性错误提示（动作失败）。
    var errorMessage: String?
    /// 一次性成功提示（toast，自动消失）。
    private(set) var successMessage: String?
    /// 一次性警告提示（非致命失败：如 pull 遇冲突，冲突文件已列入工作区，不弹错误 alert）。
    private(set) var warningMessage: String?
    /// 提示令牌：新提示会作废旧提示的定时清除。
    private var toastToken = UUID()

    /// 流式操作控制台（clone/fetch/pull/push/merge/rebase）逐行输出与标题。
    var consoleLines: [String] = []
    var consoleTitle: String = ""
    /// 控制台是否浮出。
    var isConsolePresented = false

    // MARK: - DevkitTool

    var dynamicTabTitle: String? { selectedRepo?.alias }
    var hasUnsavedContent: Bool { false }

    func makeView() -> AnyView { AnyView(GitToolView(tool: self)) }

    func teardownOnTabClose() { /* git 操作均为一次性子进程，无常驻资源需收尾 */ }

    // MARK: - 仓库选择 / 刷新

    func select(repo: GitRepo) {
        selectedRepo = repo
        section = .changes
        errorMessage = nil
        Task { await refreshAll() }
    }

    /// 结束当前仓库视图（回到未选择占位）。
    func clearSelection() {
        selectedRepo = nil
        status = .empty
        commits = []
    }

    /// 改当前仓库绑定的密钥（`nil` = 不绑定）：立即回写集合并刷新远程环境。
    func rebindKey(to keyID: UUID?) {
        guard var repo = selectedRepo else { return }
        repo.keyID = keyID
        try? GitRepoStore.save(repo)
        selectedRepo = repo
    }

    private func repository() -> GitRepository? {
        guard let repo = selectedRepo else { return nil }
        return GitRepository(repo: repo)
    }

    /// 刷新当前仓库的全部只读数据。
    func refreshAll() async {
        guard let repo = selectedRepo, repo.isValid else {
            status = .empty
            unpushedCommits = []
            return
        }
        let git = GitRepository(repo: repo)
        isBusy = true
        defer { isBusy = false }
        if let s = try? await git.status() { status = s }
        if let b = try? await git.branches() {
            localBranches = b.local
            remoteBranches = b.remote
        }
        if let r = try? await git.remotes() { remotes = r }
        unpushedCommits = (try? await git.unpushedCommits()) ?? []
        await loadLog(reset: true, git: git)
    }

    /// 仅刷新状态（提交/暂存后调用，成本低）。
    func refreshStatus() async {
        guard let git = repository() else { return }
        if let s = try? await git.status() { status = s }
    }

    func loadLog(reset: Bool, git: GitRepository? = nil) async {
        guard let git = git ?? repository() else { return }
        if reset {
            commits = []
            logLoaded = 0
        }
        let batch = (try? await git.log(count: Self.logPageSize, skip: logLoaded)) ?? []
        commits.append(contentsOf: batch)
        logLoaded += batch.count
    }

    func loadMoreLog() async {
        guard commits.count >= logLoaded || logLoaded > 0 else { return }
        await loadLog(reset: false)
    }

    func refreshStashes() async {
        guard let git = repository() else { return }
        stashes = (try? await git.stashList()) ?? []
    }

    func refreshTags() async {
        guard let git = repository() else { return }
        tags = (try? await git.tags()) ?? []
    }

    // MARK: - 动作封装

    /// 弹出一条自动消失的提示胶囊（成功=绿 / 警告=橙），新提示立即作废旧提示的定时清除。
    private func showToast(_ message: String, warning: Bool) {
        if warning { warningMessage = message } else { successMessage = message }
        let token = UUID()
        toastToken = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.toastToken == token else { return }
            if warning { self.warningMessage = nil } else { self.successMessage = nil }
        }
    }

    /// 动作失败分流：若刷新后工作区存在冲突文件（如 pull 因本地改动/合并冲突中断），
    /// 不弹错误 alert，改为警告 toast + 自动打开首个冲突文件的预览；否则照常报错。
    private func handleFailureOrConflict(_ error: Error) {
        if hasConflict {
            errorMessage = nil
            section = .changes   // 确保预览面板所在分区可见
            showToast("存在冲突：已在变更区列出冲突文件，请逐块解决", warning: true)
            let first = status.conflicted[0]
            Task { await selectFileForDiff(first) }
        } else {
            errorMessage = error.localizedDescription
        }
    }

    /// 同步类动作（pull / merge / 同步）失败分流：真正冲突时同上；
    /// 未落定冲突的中止（如「本地改动会被覆盖，Aborting」）也用警告胶囊替代弹窗，
    /// 被阻塞的文件本就列在变更区，用户可直接处理。
    private func handleSyncFailureOrConflict(_ error: Error) {
        if hasConflict {
            handleFailureOrConflict(error)
            return
        }
        let text = error.localizedDescription
        let kept = text.split(separator: "\n").filter {
            !$0.hasPrefix("From ") && !$0.hasPrefix("Fetching") && !Set($0).isEmpty
        }
        // 优先保留 error/fatal 行，其次取前三行摘要。
        let brief = (kept.first { $0.contains("error:") || $0.contains("fatal:") }.map { [$0] } ?? Array(kept.prefix(3)))
            .joined(separator: " ")
        showToast("未能完成拉取：\(brief.isEmpty ? "请查看变更区后重试" : brief)", warning: true)
    }

    /// 执行一个非流式动作：忙锁 + 错误捕获 + 成功后刷新状态（可选成功 toast）。
    private func perform(_ action: @escaping (GitRepository) async throws -> Void,
                         thenRefresh: Bool = true,
                         success: String? = nil) async {
        guard let repo = selectedRepo, repo.isValid else {
            errorMessage = "仓库路径不存在或已失效"
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await action(GitRepository(repo: repo))
            if thenRefresh { await refreshAll() }
            if let success { showToast(success, warning: false) }
        } catch {
            // 先刷新再分流：冲突导致的失败（如按块解决后手工编辑引入异常）不弹 alert。
            await refreshStatus()
            handleFailureOrConflict(error)
        }
    }

    /// 执行一个流式动作：默认把输出弹到控制台；`presentsConsole: false` 时后台静默执行（仅忙轮询动画）。
    /// `syncFailure`：失败分流策略——普通动作照常弹错误；pull/merge/rebase 用冲突友好的警告提示。
    private func performStreaming(title: String,
                                  presentsConsole: Bool = true,
                                  syncFailure: Bool = false,
                                  success: String? = nil,
                                  _ action: @escaping (GitRepository, @escaping @MainActor (String) -> Void) async throws -> Void) async {
        guard let repo = selectedRepo, repo.isValid else {
            errorMessage = "仓库路径不存在或已失效"
            return
        }
        isBusy = true
        errorMessage = nil
        if presentsConsole {
            consoleTitle = title
            consoleLines = []
            isConsolePresented = true
        }
        defer { isBusy = false }
        let git = GitRepository(repo: repo)
        let append: @MainActor (String) -> Void = { [weak self] line in
            guard let self, presentsConsole else { return }
            self.consoleLines.append(line)
        }
        do {
            try await action(git, append)
            await refreshAll()
            if let success { showToast(success, warning: false) }
        } catch {
            if presentsConsole { consoleLines.append("✗ " + error.localizedDescription) }
            // 拉取/合并/变基因冲突中断：不弹错误，改为在工作区展示冲突文件 + 警告 toast。
            await refreshAll()
            if syncFailure { handleSyncFailureOrConflict(error) } else { handleFailureOrConflict(error) }
        }
    }

    // —— 暂存 / 提交 ——

    func stage(paths: [String]) async { await perform { try await $0.stage(paths: paths) } }
    func stageAll() async { await perform { try await $0.stageAll() } }
    func unstage(paths: [String]) async { await perform { try await $0.unstage(paths: paths) } }
    func unstageAll() async { await perform { try await $0.unstageAll() } }
    func discard(paths: [String]) async { await perform { try await $0.discard(paths: paths) } }
    func commit(message: String, amend: Bool) async {
        await perform({ try await $0.commit(message: message, amend: amend) }, success: "已提交")
    }

    // —— 远程 ——

    func fetch() async { await performStreaming(title: "git fetch", presentsConsole: false, success: "已 fetch") { git, line in try await git.fetch(remote: nil, onLine: line) } }
    func pull() async { await performStreaming(title: "git pull", presentsConsole: false, syncFailure: true, success: "已拉取") { git, line in try await git.pull(onLine: line) } }
    func push() async { await performStreaming(title: "git push", presentsConsole: false, success: "已推送") { git, line in try await git.push(onLine: line) } }

    /// 刷新工作区：重读 status / 分支 / 历史（仅本地，不联网），驱动该按钮转圈。
    func refreshWorkspace() async {
        guard !isBusy else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshAll()
    }

    /// 拉取代码：`git pull`（静默），驱动该按钮转圈。
    func pullCode() async {
        guard !isBusy else { return }
        isPulling = true
        defer { isPulling = false }
        await pull()
    }

    /// 拉取后自动推送（同步）：pull 成功才 push；pull 失败（如冲突）则不推送。后台静默，仅忙轮询动画。
    func pullThenPush() async {
        guard let repo = selectedRepo, repo.isValid else {
            errorMessage = "仓库路径不存在或已失效"
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let git = GitRepository(repo: repo)
        do {
            try await git.pull()
            try await git.push()
            await refreshAll()
            showToast("已拉取并推送", warning: false)
        } catch {
            // 同步失败可能是冲突导致：先刷新再分流，冲突时不弹错误。
            await refreshAll()
            handleSyncFailureOrConflict(error)
        }
    }

    // —— 分支 ——

    func checkout(branch: String) async { await perform { try await $0.checkout(branch: branch) } }
    func createBranch(name: String, checkout: Bool) async {
        await perform { try await $0.createBranch(name: name, checkout: checkout) }
    }
    func deleteBranch(name: String, force: Bool) async {
        await perform { try await $0.deleteBranch(name: name, force: force) }
    }
    func merge(branch: String) async {
        await performStreaming(title: "git merge \(branch)", syncFailure: true) { git, line in try await git.merge(branch: branch, onLine: line) }
    }

    // —— Stash ——

    func stashPush(message: String) async { await perform { try await $0.stashPush(message: message) } }
    func stashPop(index: Int) async { await perform { try await $0.stashPop(index: index) } }
    func stashApply(index: Int) async { await perform { try await $0.stashApply(index: index) } }
    func stashDrop(index: Int) async { await perform { try await $0.stashDrop(index: index) } }

    // —— 高级 ——

    func rebase(onto: String) async {
        await performStreaming(title: "git rebase \(onto)", syncFailure: true) { git, line in try await git.rebase(onto: onto, onLine: line) }
    }
    func rebaseAbort() async { await perform { try await $0.rebaseAbort() } }
    func cherryPick(hash: String) async { await perform { try await $0.cherryPick(hash: hash) } }
    func reset(mode: GitRepository.ResetMode, to: String) async {
        await perform { try await $0.reset(mode: mode, to: to) }
    }
    func createTag(name: String) async { await perform { try await $0.createTag(name: name) } }
    func deleteTag(name: String) async { await perform { try await $0.deleteTag(name: name) } }
    func resolveConflict(file: String, side: GitRepository.ConflictSide) async {
        await perform { try await $0.resolveConflict(file: file, side: side) }
    }
    func markResolved(file: String) async { await perform { try await $0.markResolved(file: file) } }

    /// 把当前绑定密钥写入仓库 config（供应用外终端使用）。
    func writeBoundKeyToConfig() async {
        guard let repo = selectedRepo, let keyID = repo.keyID,
              let key = GitKeyStore.load(id: keyID), let fileName = key.privateFileName,
              let url = GitKeyStorage.resolvedPrivateURL(fileName: fileName) else {
            errorMessage = "当前仓库未绑定有效密钥"
            return
        }
        GitKeyStorage.ensureUsable(fileName: fileName)
        let cmd = GitSSHBridge.sshCommand(privateKeyPath: url.path)
        await perform { try await $0.writeSSHCommandToConfig(cmd) }
    }

    // MARK: - 会话持久化

    private struct SessionState: Codable {
        var repoID: UUID?
        var section: Section
    }

    @MainActor func sessionStateData() -> Data? {
        guard let repoID = selectedRepo?.id else { return nil }
        return try? JSONEncoder().encode(SessionState(repoID: repoID, section: section))
    }

    /// 恢复只回填选中的仓库与分区并刷新只读数据；不自动执行任何写 / 网络操作。
    @MainActor func restoreSessionState(_ data: Data) {
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data),
              let id = state.repoID,
              let repo = GitRepoStore.load(id: id)
        else { return }
        selectedRepo = repo
        section = state.section
        Task { await refreshAll() }
    }
}
