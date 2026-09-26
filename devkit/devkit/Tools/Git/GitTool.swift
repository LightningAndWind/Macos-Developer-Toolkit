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

    /// 是否有待推送内容（有未推送提交 → 可推送）。
    var hasUnpushed: Bool { !unpushedCommits.isEmpty }

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
    /// 成功提示令牌：新提示会作废旧提示的定时清除。
    private var successToken = UUID()

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

    /// 弹出一条自动消失的成功 toast。
    private func showSuccess(_ message: String) {
        successMessage = message
        let token = UUID()
        successToken = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.successToken == token else { return }
            self.successMessage = nil
        }
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
            if let success { showSuccess(success) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 执行一个流式动作：默认把输出弹到控制台；`presentsConsole: false` 时后台静默执行（仅忙轮询动画），失败仍弹错误。
    private func performStreaming(title: String,
                                  presentsConsole: Bool = true,
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
            if let success { showSuccess(success) }
        } catch {
            errorMessage = error.localizedDescription
            if presentsConsole { consoleLines.append("✗ " + error.localizedDescription) }
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
    func pull() async { await performStreaming(title: "git pull", presentsConsole: false, success: "已拉取") { git, line in try await git.pull(onLine: line) } }
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
            showSuccess("已拉取并推送")
        } catch {
            errorMessage = error.localizedDescription
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
        await performStreaming(title: "git merge \(branch)") { git, line in try await git.merge(branch: branch, onLine: line) }
    }

    // —— Stash ——

    func stashPush(message: String) async { await perform { try await $0.stashPush(message: message) } }
    func stashPop(index: Int) async { await perform { try await $0.stashPop(index: index) } }
    func stashApply(index: Int) async { await perform { try await $0.stashApply(index: index) } }
    func stashDrop(index: Int) async { await perform { try await $0.stashDrop(index: index) } }

    // —— 高级 ——

    func rebase(onto: String) async {
        await performStreaming(title: "git rebase \(onto)") { git, line in try await git.rebase(onto: onto, onLine: line) }
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
