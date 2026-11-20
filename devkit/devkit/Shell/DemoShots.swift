//
//  DemoShots.swift
//  devkit
//
//  调试专用（仅 DEBUG）：README 截图生成器。进程内把应用驱动到各个「演示场景」，
//  每个场景就绪后写入 current.txt 并等待同名 .done 文件，由外部脚本对真实窗口
//  `screencapture`（真窗口渲染毛玻璃材质，优于 cacheDisplay），实现零 UI 自动化权限的
//  确定性截图。与 SheetProbe 同一模式，但场景是完整应用状态而非单个 sheet。
//
//  用法（数据目录必须是空的临时目录，避免污染真实数据）：
//    DEVKIT_DATA_DIR=/tmp/devkit-shot-data \
//    DEVKIT_SHOTS_DIR=/tmp/devkit-shot/run \
//    <app>/Contents/MacOS/devkit
//  外部脚本循环读 current.txt → screencapture → touch <scene>.done；
//  全部场景结束后等待 quit.done 再 exit(0)。
//
//  演示内容刻意使用虚构数据（10.0.1.x、devkit-demo 仓库等），不涉及任何真实凭据。
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum DemoShots {
    /// 演示用本地夹具服务器（外部脚本负责启动）。
    private static let fixtureBase = "http://127.0.0.1:8199"
    /// 演示 Git 仓库 / SFTP 目录（外部脚本负责准备，缺失则跳过对应场景的数据准备）。
    private static let demoRepoPath = "/tmp/devkit-demo-repo"
    private static let demoFilesPath = "/tmp/devkit-demo-files"
    private static let demoBackupPath = "/tmp/devkit-demo-backup"

    static func runIfRequested(appState: AppState) {
        guard let raw = ProcessInfo.processInfo.environment["DEVKIT_SHOTS_DIR"], !raw.isEmpty else { return }
        let base = URL(fileURLWithPath: raw, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        Task {
            prepareWindow()
            seedDemoData()
            // 等首帧渲染稳定。
            try? await Task.sleep(nanoseconds: 800_000_000)

            let tm = appState.tabManager
            let registry = ToolRegistry.shared

            // 先开齐全部工具标签：之后每张截图的侧栏都是完整状态。
            var httpTab: Tab?
            var jsonTab: Tab?
            var sshTab: Tab?
            var gitTab: Tab?
            var sftpTab: Tab?
            for id in ["tool.http", "tool.json", "tool.ssh", "tool.git", "tool.sftp"] {
                guard let d = registry.descriptor(for: id) else { continue }
                let tab = tm.openTool(descriptor: d)
                switch id {
                case "tool.http": httpTab = tab
                case "tool.json": jsonTab = tab
                case "tool.ssh": sshTab = tab
                case "tool.git": gitTab = tab
                case "tool.sftp": sftpTab = tab
                default: break
                }
            }

            // ── 场景 1：HTTP 请求 ─────────────────────────────────────────
            if let tab = httpTab {
                if let tool = appState.httpTool(forTab: tab.id) {
                    // 先发一次 /api/stats 充实历史列表，再发目标请求作为最终画面。
                    tool.request = HTTPRequestModel(method: "GET", urlString: "\(fixtureBase)/api/stats")
                    tool.send()
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    var request = HTTPRequestModel(method: "GET", urlString: "\(fixtureBase)/api/users")
                    request.params = [
                        HTTPKV(key: "page", value: "1"),
                        HTTPKV(key: "page_size", value: "20"),
                    ]
                    request.auth = HTTPAuthModel(kind: .bearer, token: "demo-token")
                    tool.request = request
                    tool.send()
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                }
                tm.select(tab.id)
                try? await Task.sleep(nanoseconds: 400_000_000)
                // 绑定为已保存请求：标签标题变干净、无未保存标记。
                let folderID = HTTPCollectionStore.allFolders().first { $0.name == "业务接口" }?.id
                appState.commitHTTPSave(tabID: tab.id, name: "用户列表", folderID: folderID)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            await signalAndWait("http", base: base)

            // ── 场景 2 / 3：JSON 文本 / 树形 ──────────────────────────────
            if let tab = jsonTab {
                if let tool = tab.toolInstance as? JSONTool {
                    tool.text = demoJSON
                    tool.viewMode = .code
                }
                tm.select(tab.id)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await signalAndWait("json", base: base)
            if let tab = jsonTab, let tool = tab.toolInstance as? JSONTool {
                tool.viewMode = .tree
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await signalAndWait("json-tree", base: base)

            // ── 场景 4：SSH 本地终端 ──────────────────────────────────────
            if let tab = sshTab {
                tm.select(tab.id)
                try? await Task.sleep(nanoseconds: 300_000_000)
                appState.sshTool(forTab: tab.id)?.startLocal()
                // 等终端视图创建并绑定 + shell 启动出提示符。
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                if let tool = appState.sshTool(forTab: tab.id) {
                    tool.terminalInput.send("export PS1='dev@devkit ~ % '", pressReturn: true)
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    tool.terminalInput.send("clear", pressReturn: true)
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    tool.terminalInput.send("sw_vers", pressReturn: true)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    tool.terminalInput.send("git --version && node --version", pressReturn: true)
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    tool.terminalInput.send("date '+%Y-%m-%d %H:%M'", pressReturn: true)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
            }
            await signalAndWait("ssh", base: base)

            // ── 场景 5：Git 管理 ──────────────────────────────────────────
            if FileManager.default.fileExists(atPath: demoRepoPath), let tab = gitTab {
                let repo = GitRepo(folderID: nil, alias: "devkit-demo",
                                   path: demoRepoPath, keyID: nil, preferredRemoteName: nil)
                try? GitRepoStore.save(repo)
                if let tool = appState.gitTool(forTab: tab.id) {
                    tool.select(repo: repo)
                    await tool.refreshAll()
                    // 选中已修改文件，让右侧出现着色 diff 预览。
                    if let entry = tool.status.entries.first(where: { $0.path == "README.md" }) {
                        await tool.selectFileForDiff(entry)
                    }
                }
                tm.select(tab.id)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await signalAndWait("git", base: base)

            // ── 场景 6：SFTP 传输（本地 ↔ 本地）───────────────────────────
            if let tab = sftpTab {
                tm.select(tab.id)
                if let tool = tab.toolInstance as? SFTPTool {
                    await tool.side(.left).connectLocal()
                    await tool.side(.right).connectLocal()
                    if FileManager.default.fileExists(atPath: demoFilesPath) {
                        await tool.side(.left).navigate(to: demoFilesPath)
                    }
                    if FileManager.default.fileExists(atPath: demoBackupPath) {
                        await tool.side(.right).navigate(to: demoBackupPath)
                    }
                    // 选中一个文件，让传输按钮进入可用态。
                    tool.side(.left).selection = ["package.json"]
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await signalAndWait("sftp", base: base)

            // ── 场景 7：新标签页 Launcher（此时侧栏已有全部演示标签）───────
            tm.isLauncherPresented = true
            try? await Task.sleep(nanoseconds: 500_000_000)
            await signalAndWait("launcher", base: base)

            // ── 场景 8：设置面板 ──────────────────────────────────────────
            appState.isSettingsPresented = true
            try? await Task.sleep(nanoseconds: 700_000_000)
            await signalAndWait("settings", base: base)

            // 收尾：等外部脚本确认后退出。
            await signalAndWait("quit", base: base)
            exit(0)
        }
    }

    // MARK: - 窗口与外观

    /// 统一窗口尺寸与外观，保证 README 截图一致：浅色外观 + 1440×900。
    private static func prepareWindow() {
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.activate(ignoringOtherApps: true)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 944)
        let size = NSSize(width: min(1440, screen.width - 60), height: min(900, screen.height - 20))
        for win in NSApp.windows where win.styleMask.contains(.titled) {
            win.setContentSize(size)
            win.setFrameOrigin(NSPoint(x: screen.minX + 30, y: screen.maxY - size.height))
            win.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - 演示数据

    /// 种子数据：SSH 连接记录（虚构主机）、HTTP 已保存请求与文件夹。
    /// Git 仓库登记放在对应场景里（需要 repo 路径存在才有意义）。
    private static func seedDemoData() {
        // SSH：一个文件夹 + 三台虚构主机。
        if let folder = SSHProfileStore.createFolder(name: "服务器", parentID: nil) {
            let hosts: [(String, String)] = [
                ("生产服务器", "10.0.1.10"),
                ("预发环境", "10.0.1.20"),
                ("构建机", "10.0.1.30"),
            ]
            for (name, host) in hosts {
                var p = SSHProfile(folderID: folder.id, name: name, host: host,
                                   port: 22, username: "root", authKind: .password)
                p.workingDirectory = "/var/www"
                try? SSHProfileStore.save(p)
            }
        }
        // 本地终端记录：打开即进入演示目录。
        if FileManager.default.fileExists(atPath: demoFilesPath) {
            let local = SSHProfile(kind: .local, name: "devkit-demo 项目",
                                   workingDirectory: demoFilesPath)
            try? SSHProfileStore.save(local)
        }
        // HTTP：文件夹 + 两条已保存请求（不绑定标签，供设置面板 / 选择器展示；
        // 当前标签绑定的「用户列表」在 HTTP 场景里按需另存）。
        if let folder = HTTPCollectionStore.createFolder(name: "业务接口", parentID: nil) {
            let saved: [(String, String, String)] = [
                ("创建订单", "POST", "/api/orders"),
                ("删除用户", "DELETE", "/api/users/7"),
            ]
            for (name, method, path) in saved {
                let tool = HTTPTool()
                tool.request = HTTPRequestModel(method: method, urlString: fixtureBase + path)
                _ = try? tool.persist(name: name, folderID: folder.id)
            }
        }
    }

    private static let demoJSON = """
        {
          "name": "devkit-demo",
          "version": "2.1.0",
          "description": "devkit 演示项目的配置文件",
          "engine": {
            "type": "sqlite",
            "journalMode": "WAL",
            "cacheSize": 2000
          },
          "tools": [
            { "id": "http", "title": "HTTP 请求", "enabled": true },
            { "id": "ssh", "title": "SSH 终端", "enabled": true },
            { "id": "git", "title": "Git 管理", "enabled": false }
          ],
          "shortcuts": {
            "newTab": "⌘T",
            "renameTab": "⌘E",
            "save": "⌘S"
          },
          "tags": ["debug", "toolkit", "macOS"],
          "count": 42,
          "ratio": 0.875,
          "releaseDate": "2026-11-01"
        }
        """

    // MARK: - 场景握手

    /// 通知外部「当前场景已就绪」，并阻塞等待外部完成截图（touch <scene>.done）。
    /// 90 秒超时自动继续，保证脚本异常时应用不至于挂死。
    private static func signalAndWait(_ scene: String, base: URL) async {
        let current = base.appendingPathComponent("current.txt")
        let done = base.appendingPathComponent("\(scene).done")
        try? FileManager.default.removeItem(at: done)
        try? scene.write(to: current, atomically: true, encoding: .utf8)
        print("[demo-shots] 场景就绪：\(scene)")
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: done.path) { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        print("[demo-shots] 等待 \(scene).done 超时，继续下一场景")
    }
}
#endif
