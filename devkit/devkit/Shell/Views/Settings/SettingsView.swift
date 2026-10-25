//
//  SettingsView.swift
//  devkit
//
//  设置面板：集中管理 HTTP 记录与终端会话记录（新增 / 删除），另含数据目录信息。
//  入口：侧栏左下角设置按钮、菜单「设置…」(⌘,)。
//
//  设计说明：
//  - 左侧为分区导轨（HTTP 记录 / 终端会话 / Git 仓库 / 通用），右侧为对应列表，仿系统设置的观感；
//  - 「已保存请求 / 终端会话记录」为用户资产，删除前弹确认；「历史记录」为过程数据，删除即时生效；
//  - 删除会同步刷新已打开标签内缓存的列表 / 绑定，避免出现「设置里删了但标签里还在」。
//

import AppKit
import SwiftUI

// MARK: - 分区

enum SettingsPanelSection: String, CaseIterable, Identifiable {
    case http
    case ssh
    case git
    case ai
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .http: return "HTTP 记录"
        case .ssh: return "终端会话"
        case .git: return "Git 仓库"
        case .ai: return "AI 接入"
        case .general: return "通用"
        }
    }

    var symbol: String {
        switch self {
        case .http: return "arrow.up.arrow.down.square"
        case .ssh: return "terminal"
        case .git: return "arrow.triangle.branch"
        case .ai: return "sparkles"
        case .general: return "gearshape"
        }
    }
}

// MARK: - 设置面板

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var section: SettingsPanelSection = .http

    /// 外观模式：直绑 UserDefaults，与根视图 `ContentView` 的 `@AppStorage` 共享同一键，改后即全局生效。
    @AppStorage(AppPreferences.appearanceModeKey)
    private var appearanceRaw: String = AppAppearanceMode.system.rawValue

    private var appearanceMode: Binding<AppAppearanceMode> {
        Binding(
            get: { AppAppearanceMode.from(raw: appearanceRaw) },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    // 数据快照：打开面板时读一次，增删后就地刷新（面板内数据量小，全量读成本可忽略）。
    @State private var savedRequests: [HTTPSavedRequest] = []
    /// 历史只取轻量摘要（不加载响应体 blob），避免为列几百条历史把大对象读进内存。
    @State private var historyRecords: [HTTPHistorySummary] = []
    /// 历史总条数（摘要只取最近 N 条，清空提示需要真实总数）。
    @State private var historyTotal = 0
    @State private var profiles: [SSHProfile] = []
    @State private var folderNames: [UUID: String] = [:]
    // Git 仓库与密钥（集中管理：改绑密钥 / 删除登记）。
    @State private var gitRepos: [GitRepo] = []
    @State private var gitKeys: [GitKey] = []

    // 集合树（无搜索词时展示层级）；搜索时退回下方扁平过滤列表。
    @State private var httpTree: [SettingsTreeNode] = []
    @State private var sshTree: [SettingsTreeNode] = []
    @State private var httpMoveTargets: [SettingsMoveTarget] = []
    @State private var sshMoveTargets: [SettingsMoveTarget] = []
    @State private var httpCollapsed: Set<UUID> = []
    @State private var sshCollapsed: Set<UUID> = []

    // 搜索（内存过滤，避免每次输入都查库）
    @State private var httpQuery = ""
    @State private var sshQuery = ""

    // 新建 / 编辑终端记录（嵌套 sheet）
    @State private var editingProfile: SSHProfile?
    @State private var editingProfileIsNew = false

    // 删除确认
    @State private var pendingDeletion: PendingDeletion?
    @State private var isConfirmingHistoryClear = false
    @State private var isConfirmingDataDirReset = false

    // AI 接入分区（端口草稿，提交时应用）
    @State private var aiPortDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            HStack(spacing: 0) {
                rail
                Divider()
                pane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 700, height: 480)
        .onAppear(perform: refresh)
        .sheet(item: $editingProfile) { profile in
            SSHProfileEditorView(draft: profile, isNew: editingProfileIsNew) { saved, connect in
                refresh()
                if connect { openInNewTab(saved) }
            }
        }
        .confirmationDialog(
            pendingDeletion?.title ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { item in
            Button("删除", role: .destructive) { performDeletion(item) }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { item in
            Text(item.message)
        }
        .confirmationDialog(
            "清空全部 HTTP 历史？",
            isPresented: $isConfirmingHistoryClear,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { clearHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(historyTotal) 条历史记录，此操作不可撤销。")
        }
        .confirmationDialog(
            "重置数据目录？",
            isPresented: $isConfirmingDataDirReset,
            titleVisibility: .visible
        ) {
            Button("重置", role: .destructive) {
                dismiss()
                appState.resetDataDirectory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将断开当前数据库并回到首次启动引导，重新选择目录。磁盘上已有的数据文件不会被删除。")
        }
    }

    // MARK: - 外框

    private var titleBar: some View {
        HStack {
            Text("设置").font(.headline)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPanelSection.allCases) { item in
                railRow(item)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(width: 156)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
    }

    private func railRow(_ item: SettingsPanelSection) -> some View {
        let isSelected = section == item
        return Button {
            section = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(item.title).font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var pane: some View {
        switch section {
        case .http: httpPane
        case .ssh: sshPane
        case .git: gitPane
        case .ai: aiPane
        case .general: generalPane
        }
    }

    // MARK: - HTTP 分区

    private var httpPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                searchField(text: $httpQuery, placeholder: "搜索名称 / URL / 方法")
                Button { newHTTPRequest() } label: {
                    Label("新建请求", systemImage: "plus")
                }
                .controlSize(.small)
                .help("打开一个新的 HTTP 标签")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    savedRequestsBlock
                    historyBlock
                }
                .padding(.trailing, 2)
                .padding(.bottom, 4)
            }
        }
        .padding(20)
    }

    private var savedRequestsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("已保存请求").font(.system(size: 12, weight: .semibold))
                countBadge(filteredSavedRequests.count)
                Spacer(minLength: 0)
            }

            if savedRequests.isEmpty {
                emptyHint("还没有已保存的请求。发送前按 ⌘S 可把当前请求存入集合。")
            } else if isSearchingHTTP {
                if filteredSavedRequests.isEmpty {
                    emptyHint("没有匹配的请求")
                } else {
                    ForEach(filteredSavedRequests) { record in
                        SettingsRecordRow(
                            badge: record.request.method.uppercased(),
                            badgeColor: HTTPDisplay.color(forMethod: record.request.method),
                            title: record.name,
                            subtitle: record.request.urlString,
                            deleteHelp: "删除该已保存请求",
                            onDelete: { pendingDeletion = .savedRequest(id: record.id, name: record.name) }
                        )
                    }
                }
            } else {
                SettingsCollectionTreeView(
                    nodes: httpTree,
                    moveTargets: httpMoveTargets,
                    collapsed: $httpCollapsed,
                    onDeleteRecord: { node in pendingDeletion = .savedRequest(id: node.id, name: node.displayName) },
                    onDeleteFolder: { node in pendingDeletion = .httpFolder(id: node.id, name: node.displayName) },
                    onMoveRecord: { node, target in
                        appState.moveSavedHTTPRequest(id: node.id, toFolder: target)
                        refresh()
                    }
                )
            }
        }
    }

    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("历史记录").font(.system(size: 12, weight: .semibold))
                countBadge(historyBadgeCount)
                Spacer(minLength: 0)
                Button(role: .destructive) { isConfirmingHistoryClear = true } label: {
                    Label("清空", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(historyTotal == 0)
                .help("清空全部 HTTP 历史")
            }

            if historyTotal == 0 {
                emptyHint("暂无历史记录。发送请求后会自动记录在这里。")
            } else if filteredHistory.isEmpty {
                emptyHint("没有匹配的历史记录")
            } else {
                ForEach(filteredHistory) { record in
                    SettingsRecordRow(
                        badge: record.method.uppercased(),
                        badgeColor: HTTPDisplay.color(forMethod: record.method),
                        title: record.url,
                        subtitle: "\(HTTPDisplay.historyTimestamp(record.timestamp)) · \(statusText(record))",
                        deleteHelp: "删除该条历史",
                        onDelete: { deleteHistory(record) }
                    )
                }
                if !isSearchingHTTP, historyTotal > historyRecords.count {
                    Text("仅显示最近 \(historyRecords.count) 条（共 \(historyTotal) 条）。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func statusText(_ record: HTTPHistorySummary) -> String {
        if let code = record.statusCode { return "HTTP \(code)" }
        return "请求失败"
    }

    // MARK: - SSH 分区

    private var sshPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                searchField(text: $sshQuery, placeholder: "搜索名称 / 主机 / 用户名 / 目录")
                Button { newSSHRecord() } label: {
                    Label("新建记录", systemImage: "plus")
                }
                .controlSize(.small)
                .help("新建本地终端记录或远程 SSH 连接")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("会话记录").font(.system(size: 12, weight: .semibold))
                        countBadge(filteredProfiles.count)
                        Spacer(minLength: 0)
                    }

                    if profiles.isEmpty {
                        emptyHint("还没有保存的终端记录。点「新建记录」添加本地终端或 SSH 连接。")
                    } else if isSearchingSSH {
                        if filteredProfiles.isEmpty {
                            emptyHint("没有匹配的记录")
                        } else {
                            ForEach(filteredProfiles) { profile in
                                SettingsRecordRow(
                                    symbol: profile.isLocal ? "house" : "terminal",
                                    symbolColor: .accentColor,
                                    title: profile.name,
                                    subtitle: "\(profile.displaySummary) · \(folderName(for: profile))",
                                    deleteHelp: "删除该记录（含其私钥文件）",
                                    onDelete: { pendingDeletion = .sshProfile(id: profile.id, name: profile.name) },
                                    onEdit: { beginEditProfile(profile.id) }
                                )
                            }
                        }
                    } else {
                        SettingsCollectionTreeView(
                            nodes: sshTree,
                            moveTargets: sshMoveTargets,
                            collapsed: $sshCollapsed,
                            onDeleteRecord: { node in pendingDeletion = .sshProfile(id: node.id, name: node.displayName) },
                            onDeleteFolder: { node in pendingDeletion = .sshFolder(id: node.id, name: node.displayName) },
                            onMoveRecord: { node, target in
                                SSHProfileStore.moveProfile(id: node.id, to: target)
                                refresh()
                            },
                            // 终端会话记录可就地编辑（名称 / 默认目录 / 主机 / 认证等）。
                            onEditRecord: { node in beginEditProfile(node.id) }
                        )
                    }
                }
                .padding(.trailing, 2)
                .padding(.bottom, 4)
            }
        }
        .padding(20)
    }

    private func folderName(for profile: SSHProfile) -> String {
        guard let id = profile.folderID, let name = folderNames[id] else { return "根目录" }
        return name
    }

    // MARK: - 通用分区

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 外观：暗色 / 亮色切换开关（“跟随系统”交回系统控制）。
            VStack(alignment: .leading, spacing: 6) {
                Text("外观").font(.system(size: 12, weight: .semibold))
                Picker("外观模式", selection: appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text("选择应用亮色 / 暗色主题；终端、侧栏与内容区会同步切换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("数据目录").font(.system(size: 12, weight: .semibold))
                Text(AppPreferences.shared.dataDirectoryURL?.path ?? "未设置")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("在访达中显示") { revealDataDirectory() }
                    Button("重置数据目录…", role: .destructive) { isConfirmingDataDirReset = true }
                }
                .controlSize(.small)
            }

            Text("HTTP 记录（已保存请求 / 历史）与终端会话记录均保存在该目录下的 devkit.sqlite3。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // MARK: - 小部件

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    private func searchField(text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: - 过滤

    /// HTTP 分区是否处于搜索态。徽标与「仅显示最近 N 条」提示都以此决定口径：
    /// 搜索时要跟列表一致（命中数），不搜索时才报真实总数。
    private var isSearchingHTTP: Bool {
        !httpQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// SSH 分区是否处于搜索态：搜索时退回扁平过滤列表，否则展示层级树。
    private var isSearchingSSH: Bool {
        !sshQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 历史徽标数字。摘要只取了最近 300 条，所以**不能**用 `historyRecords.count` 冒充总数。
    private var historyBadgeCount: Int {
        isSearchingHTTP ? filteredHistory.count : historyTotal
    }

    private var filteredSavedRequests: [HTTPSavedRequest] {
        let q = httpQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return savedRequests }
        return savedRequests.filter {
            $0.name.lowercased().contains(q)
                || $0.request.urlString.lowercased().contains(q)
                || $0.request.method.lowercased().contains(q)
        }
    }

    private var filteredHistory: [HTTPHistorySummary] {
        let q = httpQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return historyRecords }
        return historyRecords.filter {
            $0.url.lowercased().contains(q) || $0.method.lowercased().contains(q)
        }
    }

    private var filteredProfiles: [SSHProfile] {
        let q = sshQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return profiles }
        return profiles.filter {
            $0.name.lowercased().contains(q)
                || $0.host.lowercased().contains(q)
                || $0.username.lowercased().contains(q)
                || ($0.workingDirectory ?? "").lowercased().contains(q)
        }
    }

    // MARK: - Git 分区

    private var gitPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("已登记仓库").font(.system(size: 12, weight: .semibold))
                countBadge(gitRepos.count)
                Spacer(minLength: 0)
            }

            if gitRepos.isEmpty {
                emptyHint("还没有登记任何 Git 仓库。打开“Git 管理”工具→选择器→登记 / 克隆。")
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(gitRepos) { repo in gitRepoRow(repo) }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(20)
    }

    private func gitRepoRow(_ repo: GitRepo) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(repo.isValid ? Color.accentColor : .orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.alias).font(.system(size: 12, weight: .semibold))
                Text(repo.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !repo.isValid {
                    Text("路径失效（可能已移动 / 换设备）").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            // 改绑密钥（仅换密钥，与新增仓库不同）。
            Menu {
                Button { rebindGitKey(repo, to: nil) } label: {
                    gitKeyLabel("不绑定（系统默认）", checked: repo.keyID == nil)
                }
                if !gitKeys.isEmpty { Divider() }
                ForEach(gitKeys) { key in
                    Button { rebindGitKey(repo, to: key.id) } label: {
                        gitKeyLabel("\(key.name) · \(key.algorithm.label)", checked: repo.keyID == key.id)
                    }
                }
            } label: {
                Label(currentKeyName(for: repo), systemImage: "key")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            // 删除登记。
            Button(role: .destructive) {
                pendingDeletion = .gitRepo(id: repo.id, name: repo.alias)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除仓库登记（不会删除磁盘文件与密钥）")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.5)))
    }

    private func gitKeyLabel(_ text: String, checked: Bool) -> some View {
        HStack { Text(text); Spacer(); if checked { Image(systemName: "checkmark") } }
    }

    private func currentKeyName(for repo: GitRepo) -> String {
        guard let keyID = repo.keyID, let key = GitKeyStore.load(id: keyID) else { return "默认密钥" }
        return key.name
    }

    /// 改仓库绑定密钥：回写集合并就地刷新列表。
    private func rebindGitKey(_ repo: GitRepo, to keyID: UUID?) {
        var updated = repo
        updated.keyID = keyID
        try? GitRepoStore.save(updated)
        refresh()
    }

    // MARK: - 数据

    private func refresh() {
        savedRequests = HTTPCollectionStore.allRequests()
        historyRecords = HTTPHistoryStore.recentSummaries(limit: 300)
        historyTotal = HTTPHistoryStore.count()
        profiles = SSHProfileStore.allRequests()
        folderNames = Dictionary(uniqueKeysWithValues: SSHProfileStore.allFolders().map { ($0.id, $0.name) })
        gitRepos = GitRepoStore.allRepos()
        gitKeys = GitKeyStore.all()
        httpTree = Self.buildHTTPTree()
        httpMoveTargets = Self.buildMoveTargets(HTTPCollectionStore.allFolders().map { ($0.id, $0.parentID, $0.name) })
        sshTree = Self.buildSSHTree()
        sshMoveTargets = Self.buildMoveTargets(SSHProfileStore.allFolders().map { ($0.id, $0.parentID, $0.name) })
    }

    // MARK: - 树构建（把各 store 的 buildTree 映射成与模型解耦的 SettingsTreeNode）

    private static func buildHTTPTree() -> [SettingsTreeNode] {
        func map(_ node: HTTPCollectionNode) -> SettingsTreeNode {
            switch node.kind {
            case .folder(let f):
                return SettingsTreeNode(id: f.id,
                                        kind: .folder(name: f.name),
                                        children: (node.children ?? []).map(map))
            case .request(let r):
                return SettingsTreeNode(id: r.id,
                                        kind: .record(title: r.name,
                                                      subtitle: r.request.urlString,
                                                      badge: r.request.method.uppercased(),
                                                      badgeColor: HTTPDisplay.color(forMethod: r.request.method),
                                                      symbol: nil,
                                                      symbolColor: nil),
                                        children: nil)
            }
        }
        return HTTPCollectionStore.buildTree().map(map)
    }

    private static func buildSSHTree() -> [SettingsTreeNode] {
        func map(_ node: SSHCollectionNode) -> SettingsTreeNode {
            switch node.kind {
            case .folder(let f):
                return SettingsTreeNode(id: f.id,
                                        kind: .folder(name: f.name),
                                        children: (node.children ?? []).map(map))
            case .profile(let p):
                // 层级已由树体现，副标题只留摘要（不再重复文件夹名）；本地记录用 house 图标区分。
                return SettingsTreeNode(id: p.id,
                                        kind: .record(title: p.name,
                                                      subtitle: p.displaySummary,
                                                      badge: nil,
                                                      badgeColor: nil,
                                                      symbol: p.isLocal ? "house" : "terminal",
                                                      symbolColor: .accentColor),
                                        children: nil)
            }
        }
        return SSHProfileStore.buildTree().map(map)
    }

    /// 把扁平文件夹列表展平成「移动到」子菜单项：首项恒为根目录，其余按层级深度缩进、名排序。
    /// 用元组入参而非协议，避免为 HTTPFolder / SSHFolder 两套同形模型再加抽象。
    private static func buildMoveTargets(
        _ folders: [(id: UUID, parentID: UUID?, name: String)]
    ) -> [SettingsMoveTarget] {
        let byParent = Dictionary(grouping: folders, by: { $0.parentID })
        var result: [SettingsMoveTarget] = [SettingsMoveTarget(id: nil, label: "根目录")]
        func walk(_ parent: UUID?, depth: Int) {
            let kids = (byParent[parent] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for f in kids {
                result.append(SettingsMoveTarget(id: f.id, label: String(repeating: "    ", count: depth) + f.name))
                walk(f.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 1)
        return result
    }

    // MARK: - 动作：新增

    /// 新增 HTTP 记录 = 开一个空白 HTTP 标签（在标签里构造并 ⌘S 保存）。
    private func newHTTPRequest() {
        appState.openTool(HTTPTool.descriptor)
        dismiss()
    }

    /// 编辑一条已有记录：从库里读回整条 profile（以 blob 为准）后交给编辑器。
    ///
    /// 必须 `load(id:)` 而不是拿列表里的值直接用：列表项是渲染用的轻量结构，
    /// 而编辑器要改的是完整记录（密码 / 私钥 / 默认目录等）。
    private func beginEditProfile(_ id: UUID) {
        guard let profile = SSHProfileStore.load(id: id) else { return }
        editingProfileIsNew = false
        editingProfile = profile
    }

    /// 新建记录 = 打开记录编辑器（默认远程 SSH 起草，可切成本地终端）；保存后列表就地刷新。
    private func newSSHRecord() {
        editingProfileIsNew = true
        editingProfile = SSHProfile(folderID: nil,
                                    name: "",
                                    host: "",
                                    port: SSHProfile.defaultPort,
                                    username: "",
                                    authKind: .password)
    }

    /// 编辑器里点「保存并连接 / 保存并打开」：新开终端标签并打开该记录。
    private func openInNewTab(_ profile: SSHProfile) {
        DispatchQueue.main.async {
            guard let tab = appState.tabManager.openTool(descriptor: SSHTool.descriptor) else { return }
            appState.sshTool(forTab: tab.id)?.open(profile)
            appState.tabManager.rename(tabID: tab.id, to: profile.name)
            appState.saveSession()
            dismiss()
        }
    }

    // MARK: - 动作：删除

    private func performDeletion(_ item: PendingDeletion) {
        switch item {
        case .savedRequest(let id, _):
            // 删除 + 解绑已打开标签 + 落盘，统一由 AppState 协调。
            appState.deleteSavedHTTPRequest(id)
        case .sshProfile(let id, _):
            // 仅移除记录（连带私钥文件）；已建立的终端会话不受影响。
            SSHProfileStore.delete(id)
        case .gitRepo(let id, _):
            // 仅移除登记 + 解绑已打开的 Git 标签（不动磁盘与密钥）。
            appState.deleteGitRepo(id)
        case .httpFolder(let id, _):
            appState.deleteHTTPFolder(id: id)
        case .sshFolder(let id, _):
            SSHProfileStore.deleteFolder(id: id)
        }
        pendingDeletion = nil
        refresh()
    }

    private func deleteHistory(_ record: HTTPHistorySummary) {
        try? HTTPHistoryStore.delete(id: record.id)
        syncOpenHTTPTabsHistory()
        refresh()
    }

    private func clearHistory() {
        try? HTTPHistoryStore.clearAll()
        syncOpenHTTPTabsHistory()
        refresh()
    }

    /// 历史被外部改动后，让已打开的 HTTP 标签重新读取列表，避免面板与标签内列表不一致。
    private func syncOpenHTTPTabsHistory() {
        for tab in appState.tabManager.tabs {
            (tab.toolInstance as? HTTPTool)?.loadHistory()
        }
    }

    private func revealDataDirectory() {
        guard let url = AppPreferences.shared.dataDirectoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - 待确认的删除

private enum PendingDeletion: Identifiable {
    case savedRequest(id: UUID, name: String)
    case sshProfile(id: UUID, name: String)
    case gitRepo(id: UUID, name: String)
    case httpFolder(id: UUID, name: String)
    case sshFolder(id: UUID, name: String)

    var id: UUID {
        switch self {
        case .savedRequest(let i, _), .sshProfile(let i, _), .gitRepo(let i, _),
             .httpFolder(let i, _), .sshFolder(let i, _):
            return i
        }
    }

    var title: String {
        switch self {
        case .savedRequest: return "删除这条已保存的请求？"
        case .sshProfile: return "删除这条终端记录？"
        case .gitRepo: return "删除这个仓库登记？"
        case .httpFolder, .sshFolder: return "删除这个文件夹？"
        }
    }

    var message: String {
        switch self {
        case .savedRequest(_, let n):
            return "「\(n)」将从集合中移除，此操作不可撤销。"
        case .sshProfile(_, let n):
            return "「\(n)」及其私钥文件将被删除，此操作不可撤销。"
        case .gitRepo(_, let n):
            return "仅移除「\(n)」的登记，磁盘上的仓库工作目录与已绑定密钥不会被删除。"
        case .httpFolder(_, let n):
            return "「\(n)」及其内部的全部文件夹与请求将被一并删除，此操作不可撤销。"
        case .sshFolder(_, let n):
            return "「\(n)」及其内部的全部文件夹与连接将被一并删除（含相关私钥文件），此操作不可撤销。"
        }
    }
}

// MARK: - 记录行

/// 设置面板中的一行记录：左侧可选方法徽标 / 图标 + 标题 + 副标题，右侧删除按钮。
///
/// 非 private：`DebugSnapshot` 需要单独渲染它来核对行内排版 —— 面板里的列表位于
/// `ScrollView` 内，而 `ImageRenderer` 不绘制 `ScrollView` 的内容（见 DebugSnapshot 注释）。
struct SettingsRecordRow: View {
    var badge: String? = nil
    var badgeColor: Color = .secondary
    var symbol: String? = nil
    var symbolColor: Color = .secondary
    let title: String
    var subtitle: String? = nil
    let deleteHelp: String
    let onDelete: () -> Void
    /// 可选的就地编辑入口；`nil` 时（如 HTTP 记录）不显示铅笔按钮。
    var onEdit: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(badgeColor)
                    .frame(minWidth: 32, alignment: .leading)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(symbolColor)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0.5)
                .help("编辑该记录（名称 / 目录 / 主机等）")
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(isHovering ? Color.red.opacity(0.85) : Color.secondary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0.5)
            .help(deleteHelp)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovering ? Theme.Palette.hoverOverlay : Color.primary.opacity(0.03))
        )
        .onHover { isHovering = $0 }
    }
}

#Preview {
    SettingsView()
        .environment(AppState.shared)
}

// MARK: - AI 接入分区（MCP）

private let aiServer = AIAccessServer.shared

extension SettingsView {
    /// 给 AI 客户端用的提示词：教模型如何使用 devkit 的 MCP 工具。
    /// 可整体复制到 AGENTS.md / 系统提示词，配合工具描述一起生效。
    private var aiUsagePrompt: String {
        """
        你可以通过 devkit 的 MCP 工具操作远程服务器与 Git 仓库。这些工具由本机 devkit 应用代理执行，
        任何 IP、用户名、密码、密钥都不会（也无法）提供给你，请勿尝试探测或索要凭据；
        工具输出中的 [REDACTED] 是脱敏占位符。

        服务器操作：
        1. ssh_list_servers：列出可用服务器（只有别名与 ID）与当前活跃会话。
        2. ssh_exec 传 server=别名或ID：一次性执行命令（独立连接），适合单次查询。
        3. 需要跨命令保持状态（cd / 环境变量 / venv 激活）时：ssh_open_session 打开会话 →
           之后每次 ssh_exec 传 session=会话ID → 用完 ssh_close_session。
        4. 命令默认 30 秒超时（timeoutSeconds 可调 5-600）；持久会话超时或空闲 30 分钟会被关闭，
           重新 ssh_open_session 即可。
        5. 远端登录 shell 需为 bash/sh/zsh 等 POSIX 系；命令须是完整脚本（heredoc 等要自行收尾）。

        Git 操作：
        1. git_list_repos 列出已登记的仓库（id / 别名 / 本地路径）。
        2. git_status 查看仓库状态；git_run 传 args 数组执行任意 git 子命令
           （如 ["pull"]、["log","-n","20"]、["commit","-m","…"]）。
        3. 绑定了密钥的仓库，fetch / pull / push 自动用 devkit 内保存的密钥认证，无需任何凭据。

        数据库操作（MySQL / Redis）：
        1. db_list_connections 列出已保存的数据库连接（id / 名称 / 类型 / 默认库）。
        2. MySQL 用 db_query 执行 SQL（可多语句，返回 TSV 表格文本）；Redis 用 db_command
           执行命令（command 每行一条，如 "SET k v\\nGET k"）。连接配置的密码与默认库会自动应用。
        3. 结果文本就是数据库的真实输出；exitCode / isError 语义同上，错误先读文本再决定下一步。
        4. 写操作（INSERT / UPDATE / DELETE / FLUSHALL 等）同样真实生效，务必与用户确认后执行。

        通用约定：
        - exitCode 非 0 是正常返回，读 stdout / stderr 判断原因，不要当作工具故障。
        - timedOut=true 表示命令超时；shellExited=true 表示远端 shell 断开（原因常在 stderr）。
        - 优先用一次性执行；确需跨命令状态才开会话，并及时关闭。
        """
    }

    private var aiPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                aiToggleBlock
                if let err = aiServer.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
                aiConnectionBlock
                aiZcodeConfigBlock
                aiPromptBlock
                aiAuditBlock
            }
            .padding(20)
        }
    }

    private var aiToggleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("启用 AI 接入（MCP）", isOn: Binding(
                    get: { aiServer.enabled },
                    set: { aiServer.setEnabled($0) }
                ))
                .font(.system(size: 12.5))
                Spacer()
                // 运行状态点
                HStack(spacing: 4) {
                    Circle()
                        .fill(aiServer.running ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(aiServer.running ? "运行中" : (aiServer.enabled ? "启动中…" : "已停止"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Text("大模型客户端（ZCode / Claude Code / Cursor 等）通过 stdio 桥接脚本连接本机 devkit，使用已保存的服务器连接、Git 密钥与数据库连接执行任务。启用后桥接脚本自动生成，把下方配置复制进客户端即可，无需手工配置端口与请求头。服务仅监听 127.0.0.1；输出中的 IP、用户名、密码一律替换为 [REDACTED]，凭据不会进入模型上下文。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aiConnectionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("连接信息").font(.system(size: 12, weight: .semibold))

            aiKVRow(label: "端点", value: aiServer.endpointURL, copyable: true)
            aiKVRow(label: "Token", value: aiServer.token.isEmpty ? "（启用后生成）" : aiServer.token,
                    copyable: !aiServer.token.isEmpty)

            HStack(spacing: 8) {
                Button("重新生成 Token") { aiServer.regenerateToken() }
                Text("重新生成后旧的立即作废，需同步更新客户端配置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                Text("端口").font(.system(size: 12))
                TextField("端口", text: $aiPortDraft)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { applyPortDraft() }
                Button("应用") { applyPortDraft() }
                    .controlSize(.small)
                Text("修改后重启服务生效（1024-65535）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        .onAppear { aiPortDraft = "\(aiServer.port)" }
    }

    private var aiZcodeConfigBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("客户端配置（stdio）").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    copyToClipboard(aiServer.zcodeConfigJSON())
                } label: {
                    Label("复制 ZCode", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                Button {
                    copyToClipboard(aiServer.genericConfigJSON())
                } label: {
                    Label("复制通用 mcpServers", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            Text("启用后桥接脚本已生成（\(AIAccessServer.bridgeScriptURL.path)）。把左侧 JSON 合并进 ~/.zcode/cli/config.json 的 mcp.servers（通用 mcpServers 格式适用于 Claude Code / Cursor），重启客户端会话即自动连接。修改端口或重新生成 Token 后需同步更新此配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(aiServer.enabled || !aiServer.token.isEmpty ? aiServer.zcodeConfigJSON() : "// 启用后显示")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 128)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    private var aiPromptBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("AI 使用提示词").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    copyToClipboard(aiUsagePrompt)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            Text("把这段说明放进 AI 客户端的上下文（AGENTS.md / CLAUDE.md / 系统提示词），模型即可正确使用这些工具。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(aiUsagePrompt)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 190)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    private var aiAuditBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("最近调用").font(.system(size: 12, weight: .semibold))
                if !aiServer.auditLog.isEmpty {
                    countBadge(aiServer.auditLog.count)
                }
                Spacer()
                Button("清空", role: .destructive) { aiServer.clearAudit() }
                    .controlSize(.small)
            }
            if aiServer.auditLog.isEmpty {
                emptyHint("还没有 AI 调用。启用并在客户端配置后，这里的记录可查看模型都做了什么。")
            } else {
                let entries = Array(aiServer.auditLog.suffix(50).reversed())
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: entry.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(entry.ok ? Color.green : Color.red)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.tool)
                                    .font(.system(size: 12, weight: .medium))
                                Text(entry.summary)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Text("\(entry.time.formatted(.dateTime.hour().minute().second())) · \(entry.durationMS)ms")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                        .padding(.vertical, 5)
                        if index < entries.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func aiKVRow(label: String, value: String, copyable: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if copyable {
                Button {
                    copyToClipboard(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("复制\(label)")
            }
        }
    }

    private func applyPortDraft() {
        guard let p = Int(aiPortDraft.trimmingCharacters(in: .whitespaces)) else { return }
        aiServer.applyPort(p)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
