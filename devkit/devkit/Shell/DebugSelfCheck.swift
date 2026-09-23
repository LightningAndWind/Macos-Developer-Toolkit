//
//  DebugSelfCheck.swift
//  devkit
//
//  调试专用（仅 DEBUG）：不依赖 UI 的逻辑自检。
//
//  为什么需要它：下面这几条路径都要靠鼠标驱动（在设置面板里删记录、按 ⌘S、关标签），
//  本机无法做 UI 自动化；而它们恰恰是最容易「静默失效」的地方 —— 比如记录被删后
//  按 ⌘S 什么都不发生，既不报错也不弹框，光看代码很容易漏。这里直接调**真实实现**跑一遍，
//  把结论打到 stdout。
//
//  用法：`DEVKIT_DATA_DIR=/tmp/x DEVKIT_SELFCHECK=1 <app>/Contents/MacOS/devkit`
//  全部通过退出码 0，否则 1（方便接进脚本）。**会写库**，请指向临时数据目录。
//
//  响应体封顶、响应缓存那几项需要一个本地夹具服务器，用 `DEVKIT_SELFCHECK_HTTP_BASE` 指定
//  （例如 `http://127.0.0.1:8123`），需提供：
//    /small.json  小响应，验证完整保留
//    /big.txt     `Content-Length` 必须大于 `HTTPClient.maxBodyBytes`，验证封顶
//    /counter     每次返回自增数字 + `Cache-Control: max-age=600`，验证绕开缓存
//  未设置该变量时这几项打印 SKIP 并跳过，不影响退出码。
//

#if DEBUG
import AppKit
import Foundation
import SwiftTerm

@MainActor
enum DebugSelfCheck {
    private static var checks = 0
    private static var failures = 0

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.environment["DEVKIT_SELFCHECK"] == "1" else { return }
        guard DatabaseManager.shared.isOpen else {
            print("[selfcheck] 数据库未打开，跳过")
            exit(2)
        }

        seedHistoryIfEmpty()
        checkHistorySummaries()
        checkSaveViaShellSelfHeals()
        checkDeleteSavedRequestDetachesTabs()
        checkFolderCascadeDeletes()
        checkSnapshotInheritsTruncation()
        checkSnapshotDecodesLegacyJSON()
        await checkResponseBodyCap()
        await checkResponseBodyCapChunked()
        await checkResponseCachingDisabled()
        await checkLocalTerminalDismantleKillsShell()
        checkRestoreTearsDownExistingTabs()   // 会清空标签，必须放最后

        print("[selfcheck] 共 \(checks) 项，失败 \(failures) 项")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 各项检查

    /// 空库时补几条历史，供「删除后计数收敛」那几项使用。
    ///
    /// 走**真实写入路径**（`HTTPHistoryStore.insert`）而不是外部 `sqlite3` 夹具：
    /// 空库时那几项原本会静默跳过（打印一行「历史为空，跳过」就过去了），等于没验；
    /// 而且手写 SQL 很容易踩 UUID 大小写这类坑，用真实路径写就不可能写错。
    private static func seedHistoryIfEmpty() {
        guard HTTPHistoryStore.count() == 0 else { return }
        for index in 0..<3 {
            let request = HTTPRequestModel(method: "GET",
                                           urlString: "https://selfcheck.local/history/\(index)")
            let response = HTTPResponseModel(
                statusCode: 200,
                headers: [(key: "Content-Type", value: "application/json")],
                bodyData: Data("{\"index\":\(index)}".utf8),
                durationMs: 5,
                isBodyTruncated: false
            )
            try? HTTPHistoryStore.insert(request: request, response: response)
        }
        print("[selfcheck] （空库：已写入 \(HTTPHistoryStore.count()) 条历史用于验证删除收敛）")
    }

    /// 历史摘要与计数：设置面板用 `recentSummaries` + `count` 代替解码完整记录，
    /// 二者必须与真实数据一致（条数、删除后的收敛）。
    private static func checkHistorySummaries() {
        let total = HTTPHistoryStore.count()
        let summaries = HTTPHistoryStore.recentSummaries(limit: 100)
        expect(summaries.count == min(total, 100),
               "recentSummaries 条数应等于 min(总数, limit)：总数 \(total)，摘要 \(summaries.count)")
        expect(summaries.allSatisfy { !$0.url.isEmpty && !$0.method.isEmpty },
               "每条摘要都应带 method 与 url")

        guard let victim = summaries.first else {
            print("[selfcheck] （历史为空，跳过删除收敛检查）")
            return
        }
        try? HTTPHistoryStore.delete(id: victim.id)
        expect(HTTPHistoryStore.count() == total - 1, "删除一条后 count 应减一")
        expect(HTTPHistoryStore.recentSummaries(limit: 100).allSatisfy { $0.id != victim.id },
               "被删的那条不应再出现在摘要里")
    }

    /// ⌘S 自愈：绑定的记录被外部删除后，`saveViaShell()` 必须**解绑**而不是静默返回。
    /// 解绑后 `isSaved` 转 false，Shell 下次 ⌘S 会改走「另存为」弹框。
    private static func checkSaveViaShellSelfHeals() {
        let tool = HTTPTool()
        tool.request = HTTPRequestModel(method: "GET", urlString: "https://selfcheck.local/selfheal")
        guard let id = try? tool.persist(name: "自检-自愈", folderID: nil) else {
            expect(false, "persist 应能写入一条已保存请求")
            return
        }
        expect(tool.isSaved, "persist 后 isSaved 应为 true")

        // 模拟设置面板把这条记录删掉
        try? HTTPCollectionStore.deleteRequest(id: id)
        expect(HTTPCollectionStore.load(id: id) == nil, "记录应已从集合删除")

        // 关键：⌘S 走的就是这个方法
        try? tool.saveViaShell()
        expect(!tool.isSaved, "记录被删后 saveViaShell 应解绑，使 isSaved 转为 false（否则 ⌘S 静默失效）")
        expect(tool.hasUnsavedContent, "解绑后应重新出现未保存标记")

        // 解绑之后应能重新另存（Shell 会走弹框路径）
        let newID = try? tool.persist(name: "自检-自愈-另存", folderID: nil)
        expect(newID != nil, "解绑后应能重新另存")
        if let newID { try? HTTPCollectionStore.deleteRequest(id: newID) }
    }

    /// 设置面板删除路径：删记录 + 解绑已打开标签 + 触发一次会话落盘。
    private static func checkDeleteSavedRequestDetachesTabs() {
        let appState = AppState.shared
        guard let tab = appState.tabManager.openTool(descriptor: HTTPTool.descriptor),
              let tool = appState.httpTool(forTab: tab.id) else {
            expect(false, "应能新建一个 HTTP 标签")
            return
        }
        tool.request = HTTPRequestModel(method: "POST", urlString: "https://selfcheck.local/detach")
        guard let id = try? tool.persist(name: "自检-待删", folderID: nil) else {
            expect(false, "persist 应能写入一条已保存请求")
            appState.closeTab(tab.id)
            return
        }
        expect(tool.isSaved, "persist 后标签应处于已保存态")

        // 反例：删除一个不存在的 id 不应影响任何标签的绑定
        //（`deleteSavedHTTPRequest` 会先确认记录真的没了才解绑）。
        appState.deleteSavedHTTPRequest(UUID())
        expect(tool.isSaved, "删除不存在的 id 不应解绑其他标签")

        appState.deleteSavedHTTPRequest(id)
        expect(HTTPCollectionStore.load(id: id) == nil, "记录应已从集合删除")
        expect(!tool.isSaved, "绑定该记录的已打开标签应被解绑")
        expect(tool.hasUnsavedContent, "解绑后标签应重新出现未保存标记")

        appState.closeTab(tab.id)
        expect(appState.tabManager.tabs.contains { $0.id == tab.id } == false, "标签应已关闭")
    }

    /// 文件夹删除的**级联**：删父文件夹必须连带删掉所有子孙文件夹与其中的请求 / 连接。
    /// 这类破坏性路径没有 UI 测试覆盖，写错了会留下「孤儿」数据（文件夹没了、请求还挂在死 id 上）。
    private static func checkFolderCascadeDeletes() {
        // HTTP：父 → 子 → 请求
        guard let parent = HTTPCollectionStore.createFolder(name: "自检父", parentID: nil),
              let child = HTTPCollectionStore.createFolder(name: "自检子", parentID: parent.id) else {
            expect(false, "应能创建两级 HTTP 文件夹")
            return
        }
        let tool = HTTPTool()
        tool.request = HTTPRequestModel(method: "GET", urlString: "https://selfcheck.local/cascade")
        let savedID = try? tool.persist(name: "自检-级联", folderID: child.id)
        expect(savedID != nil, "应能把请求存进子文件夹")

        try? HTTPCollectionStore.deleteFolder(id: parent.id)
        expect(HTTPCollectionStore.allFolders().allSatisfy { $0.id != parent.id && $0.id != child.id },
               "删除 HTTP 父文件夹应连带删除子文件夹")
        if let savedID {
            expect(HTTPCollectionStore.load(id: savedID) == nil, "子文件夹里的请求应被连带删除")
        }

        // SSH：父 → 子 → 连接
        guard let sshParent = SSHProfileStore.createFolder(name: "自检父", parentID: nil),
              let sshChild = SSHProfileStore.createFolder(name: "自检子", parentID: sshParent.id) else {
            expect(false, "应能创建两级 SSH 文件夹")
            return
        }
        var profile = SSHProfile(folderID: sshChild.id, name: "自检连接", host: "selfcheck.local",
                                 port: 22, username: "root", authKind: .password)
        profile.password = "x"
        try? SSHProfileStore.save(profile)
        expect(SSHProfileStore.allRequests().contains { $0.id == profile.id }, "SSH 连接应已保存")

        SSHProfileStore.deleteFolder(id: sshParent.id)
        expect(SSHProfileStore.allFolders().allSatisfy { $0.id != sshParent.id && $0.id != sshChild.id },
               "删除 SSH 父文件夹应连带删除子文件夹")
        expect(!SSHProfileStore.allRequests().contains { $0.id == profile.id },
               "SSH 子文件夹里的连接应被连带删除")
    }

    /// 恢复会话会**整体替换**标签数组：替换前必须给旧标签发收尾通知，
    /// 否则旧工具会带着连接 / 子进程被静默丢弃。
    private static func checkRestoreTearsDownExistingTabs() {
        let appState = AppState.shared
        guard let tab = appState.tabManager.openTool(descriptor: SSHTool.descriptor),
              let tool = appState.sshTool(forTab: tab.id) else {
            expect(false, "应能新建一个 SSH 标签")
            return
        }
        tool.startLocal()
        expect(tool.sessionKind == .local, "会话应已进入本地态")

        // 用一个空会话恢复：现有标签会被整体替换掉
        appState.tabManager.restore(
            WindowSessionSnapshot(windowID: UUID(), tabs: [], groups: [], selectedTabID: nil)
        )
        expect(tool.sessionKind == nil, "restore 替换标签前应给旧标签发收尾通知（teardownOnTabClose 清空会话）")
        expect(appState.tabManager.tabs.isEmpty, "restore 后应变成空会话")
    }

    /// 历史快照应**继承**运行时的截断标记。
    ///
    /// 历史上限（1 MB）目前小于运行时上限（10 MB），所以单看 `bodyData.count > maxBodyBytes`
    /// 判断，恰好不会暴露问题；一旦运行时上限被调到 1 MB 以下，漏掉继承就会把
    /// 「已被截断」的快照标成完整 —— 用户看到半截响应却没有任何提示。
    /// 这里用一个「远大于 bodyData 的 maxBodyBytes」把继承逻辑单独逼出来。
    private static func checkSnapshotInheritsTruncation() {
        let truncated = HTTPResponseModel(
            statusCode: 200,
            headers: [],
            bodyData: Data(repeating: 0x41, count: 1024),
            durationMs: 1,
            isBodyTruncated: true
        )
        let inherited = HTTPResponseSnapshot(from: truncated, maxBodyBytes: 1_048_576)
        expect(inherited.isBodyTruncated, "快照应继承运行时的截断标记（否则半截响应会被当作完整）")
        expect(inherited.bodyData.count == 1024, "未超历史上限时不应再截断响应体")

        let whole = HTTPResponseModel(
            statusCode: 200,
            headers: [],
            bodyData: Data(repeating: 0x41, count: 1024),
            durationMs: 1,
            isBodyTruncated: false
        )
        expect(!HTTPResponseSnapshot(from: whole, maxBodyBytes: 1_048_576).isBodyTruncated,
               "完整响应不应被标记截断")
    }

    /// 旧版本写入的历史响应快照必须能解码。
    ///
    /// `isBodyTruncated` 是后加的字段：旧版本写的 `response` JSON 里没有这个键。若用 Codable
    /// 合成解码（非可选属性走 `decode(_:)`），旧 JSON 会抛 `keyNotFound`，而 `fetch` 里是
    /// `try?` 吞错 —— 表现为**升级后所有旧历史记录从列表里静默消失**（库里还在，UI 看不见）。
    ///
    /// 这里直接构造一段旧格式 JSON（无 `isBodyTruncated` 键）解码到当前类型：
    /// 必须成功且回退 `false`；新格式（带键）的 true/false 也都必须原样读出。
    private static func checkSnapshotDecodesLegacyJSON() {
        // bodyData 在 JSON 里是 base64；"eyJvayI6dHJ1ZX0=" 即 {"ok":true}
        let legacyJSON = #"{"statusCode":200,"durationMs":42,"headers":[],"bodyData":"eyJvayI6dHJ1ZX0="}"#
        do {
            let snapshot = try JSONDecoder().decode(HTTPResponseSnapshot.self, from: Data(legacyJSON.utf8))
            expect(!snapshot.isBodyTruncated, "旧格式快照（无 isBodyTruncated 键）解码后应回退为 false")
            expect(snapshot.statusCode == 200 && snapshot.bodyData == Data(#"{"ok":true}"#.utf8),
                   "旧格式快照解码后其余字段应保持原值")
        } catch {
            expect(false, "旧格式响应快照应能解码（实际失败：\(error.localizedDescription)）—— 否则升级后旧历史记录会整条静默消失")
        }

        let newTrue = #"{"statusCode":200,"durationMs":42,"headers":[],"bodyData":"eyJvayI6dHJ1ZX0=","isBodyTruncated":true}"#
        let newFalse = #"{"statusCode":404,"durationMs":9,"headers":[],"bodyData":"eHg=","isBodyTruncated":false}"#
        expect((try? JSONDecoder().decode(HTTPResponseSnapshot.self, from: Data(newTrue.utf8)))?.isBodyTruncated == true,
               "新格式快照应原样读出 isBodyTruncated=true")
        expect((try? JSONDecoder().decode(HTTPResponseSnapshot.self, from: Data(newFalse.utf8)))?.isBodyTruncated == false,
               "新格式快照应原样读出 isBodyTruncated=false")
    }

    /// 自检夹具服务器的基地址（`DEVKIT_SELFCHECK_HTTP_BASE`）。
    ///
    /// 需要真实网络行为才能验证的检查项都用它；未配置时各项自行打印 SKIP，
    /// 不影响退出码 —— 这样自检在没有夹具的环境里也能跑完其余部分。
    private static var fixtureBase: String? {
        guard let base = ProcessInfo.processInfo.environment["DEVKIT_SELFCHECK_HTTP_BASE"],
              !base.isEmpty else { return nil }
        return base
    }

    /// 响应体封顶：**必须真发一次请求**才验证得了。
    ///
    /// 这条路径的要害是「到达上限即中止传输」，而断言 `maxBodyBytes == 10 MB` 只是把配置
    /// 再念一遍（恒过）。所以这里打真实服务器，用一个 `Content-Length` 明确大于上限的夹具，
    /// 同时断言「服务器声明确实超限」+「客户端恰好只留了上限字节」——
    /// 前者防止夹具变小后检查变成空转，后者才是真正的行为断言。
    ///
    /// 需要外部提供夹具服务器（见 `DEVKIT_SELFCHECK_HTTP_BASE`）；未设置时跳过并打印 SKIP。
    private static func checkResponseBodyCap() async {
        guard let base = fixtureBase else {
            print("[selfcheck] SKIP  响应体封顶（未设置 DEVKIT_SELFCHECK_HTTP_BASE）")
            return
        }

        // 1) 小响应：完整保留，不应被标记截断
        do {
            let response = try await HTTPClient().send(
                HTTPRequestModel(method: "GET", urlString: "\(base)/small.json")
            )
            expect(response.statusCode == 200, "小响应应返回 200（实际 \(response.statusCode)）")
            expect(!response.isBodyTruncated, "小响应不应被标记截断")
            expect(response.sizeBytes > 0 && response.sizeBytes < HTTPClient.maxBodyBytes,
                   "小响应应完整保留（\(response.sizeBytes) 字节）")
            expect(response.bodyText?.contains("\"ok\"") == true, "小响应体应能作为文本读出")
        } catch {
            expect(false, "小响应请求不应失败：\(error.localizedDescription)")
        }

        // 2) 大响应：必须在封顶处截断
        do {
            let response = try await HTTPClient().send(
                HTTPRequestModel(method: "GET", urlString: "\(base)/big.txt")
            )
            let declared = response.headers
                .first { $0.key.lowercased() == "content-length" }
                .flatMap { Int($0.value) }
            expect((declared ?? 0) > HTTPClient.maxBodyBytes,
                   "夹具声明的长度应大于上限（Content-Length=\(declared.map(String.init) ?? "无")），否则本项检查无意义")
            expect(response.statusCode == 200, "大响应应返回 200（实际 \(response.statusCode)）")
            expect(response.isBodyTruncated, "超过上限的响应应被标记截断")
            expect(response.sizeBytes == HTTPClient.maxBodyBytes,
                   "截断后应恰好保留上限字节（实际 \(response.sizeBytes)，上限 \(HTTPClient.maxBodyBytes)）")
        } catch {
            expect(false, "大响应请求不应失败：\(error.localizedDescription)")
        }
    }

    /// chunked 传输下的封顶：封顶循环**不依赖 Content-Length**。
    ///
    /// `/big.txt` 带显式 Content-Length；但真实世界里大响应常以 `Transfer-Encoding: chunked`
    /// 到达（无总长度、逐块到达）。若接收路径里有任何按 Content-Length 预读 / 预分配的
    /// 逻辑，chunked 就会表现不同（挂死、提前结束或漏截断）。`bytes(for:)` 对两种帧法
    /// 都应表现为「逐字节序列」，封顶 break 后 `AsyncBytes` 析构取消底层 task。
    /// 夹具有效性断言是「响应头**没有** Content-Length」，与 `/big.txt` 的断言互补 ——
    /// 若夹具退化成带长度响应，本项会自动失去意义并可见。
    private static func checkResponseBodyCapChunked() async {
        guard let base = fixtureBase else {
            print("[selfcheck] SKIP  chunked 封顶（未设置 DEVKIT_SELFCHECK_HTTP_BASE）")
            return
        }

        do {
            let response = try await HTTPClient().send(
                HTTPRequestModel(method: "GET", urlString: "\(base)/big-chunked")
            )
            expect(response.headers.allSatisfy { $0.key.lowercased() != "content-length" },
                   "chunked 夹具不应带 Content-Length（实际头：\(response.headers.map { $0.key })），否则本项退化为重复验证")
            expect(response.statusCode == 200, "chunked 大响应应返回 200（实际 \(response.statusCode)）")
            expect(response.isBodyTruncated, "chunked 超限响应应被标记截断")
            expect(response.sizeBytes == HTTPClient.maxBodyBytes,
                   "chunked 截断后应恰好保留上限字节（实际 \(response.sizeBytes)，上限 \(HTTPClient.maxBodyBytes)）")
        } catch {
            expect(false, "chunked 大响应请求不应失败：\(error.localizedDescription)")
        }
    }

    /// 响应缓存必须被绕开。
    ///
    /// 这是调试工具，用户要看的是「服务器此刻真实返回了什么」。若用 `URLSession.shared`
    /// （默认 `.useProtocolCachePolicy` + 磁盘缓存），重复发同一个 GET 会直接命中缓存返回
    /// **旧响应** —— 状态码、耗时、响应体全对不上真实情况，而且现象是「时好时坏」，
    /// 极难联想到缓存。Postman / Insomnia 这类 API 客户端同样默认绕开缓存。
    ///
    /// 夹具的 `/counter` 每次返回自增数字并带 `Cache-Control: max-age=600`：
    /// 缓存生效时两次请求会拿到**同一个数字**，所以「两次不同」才是缓存被绕开的证据。
    /// 光断言「配置里关了缓存」是把配置再念一遍，恒过 —— 必须看响应。
    private static func checkResponseCachingDisabled() async {
        guard let base = fixtureBase else {
            print("[selfcheck] SKIP  响应缓存（未设置 DEVKIT_SELFCHECK_HTTP_BASE）")
            return
        }

        do {
            let first = try await HTTPClient().send(
                HTTPRequestModel(method: "GET", urlString: "\(base)/counter")
            )
            let second = try await HTTPClient().send(
                HTTPRequestModel(method: "GET", urlString: "\(base)/counter")
            )
            guard let a = first.bodyText, let b = second.bodyText else {
                expect(false, "计数端点应返回可读文本")
                return
            }
            expect(first.statusCode == 200 && second.statusCode == 200,
                   "计数端点应返回 200（实际 \(first.statusCode) / \(second.statusCode)）")
            expect(a != b,
                   "两次请求应拿到不同计数（第一次 \(a)，第二次 \(b)）—— 相同即命中响应缓存，用户会看到旧响应")
        } catch {
            expect(false, "计数端点请求不应失败：\(error.localizedDescription)")
        }
    }

    /// 关闭本地终端标签时必须结束 shell。
    ///
    /// `LocalTerminalContainer.dismantleNSView` 是本地 shell **唯一**的收尾钩子：SwiftTerm 的
    /// `LocalProcess.deinit` 只取消子进程监视器，不杀 shell、不关 PTY fd。这个钩子一旦被误删 /
    /// 改成空操作，每次关闭本地终端标签都会留下一个孤儿 shell 和一个泄漏的 PTY master fd
    /// —— 进程监视器里能看到 `zsh` 堆积，界面上却毫无异常，纯属静默泄漏。
    ///
    /// 夹具用 `/bin/sleep 300` 而不是真实 shell：启动快、收到 SIGTERM 即退、没有 zshrc 副作用。
    /// 判定「已结束」不能只看 `kill(pid, 0)`：`terminate()` 会取消本该负责 `waitpid` 回收的
    /// 监视器，子进程死后可能短暂处于 zombie 态，而僵尸对 kill 探测照样返回 0 ——
    /// 要用 `waitpid(WNOHANG)`（>0 = 僵尸由本次调用回收；-1/ECHILD = 已被监视器回收）。
    private static func checkLocalTerminalDismantleKillsShell() async {
        let view = LocalProcessTerminalView(frame: .zero)
        view.startProcess(executable: "/bin/sleep", args: ["300"], currentDirectory: NSHomeDirectory())
        let pid = view.process.shellPid

        // 先证夹具有效（否则后面的行为断言是空转）。
        // 注意 kill 的 pid 参数为 0 时语义是「整个进程组」，必须先排除 pid <= 0 再探测。
        expect(pid > 0, "夹具子进程应已启动（pid=\(pid)），否则本项检查无意义")
        guard pid > 0, kill(pid, 0) == 0 else {
            view.terminate()   // 兜底清理，避免夹具自身变成泄漏源
            return
        }

        // 行为断言：dismantle（关标签时 SwiftUI 唯一会调的收尾钩子）必须结束子进程并关闭 PTY fd
        LocalTerminalContainer.dismantleNSView(view, coordinator: LocalTerminalContainer.Coordinator())

        var gone = false
        for _ in 0..<100 {   // 上限 5s；实际 SIGTERM 后毫秒级退出
            if childProcessGone(pid: pid) { gone = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        expect(gone, "dismantle 后本地终端子进程应已结束（pid=\(pid)）—— 仍存活即收尾钩子失效，会留下孤儿 shell")
        expect(view.process.childfd == -1, "dismantle 后 PTY fd 应已关闭（childfd=\(view.process.childfd)，-1 为已关）")
    }

    /// 子进程是否已彻底结束（含「死后已被回收」）。见 `checkLocalTerminalDismantleKillsShell` 注释。
    private static func childProcessGone(pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result > 0 { return true }            // 本次调用回收了僵尸
        if result < 0 { return errno == ECHILD } // 已被 SwiftTerm 的监视器回收
        return false                             // 仍存活，继续等
    }

    // MARK: - 断言

    private static func expect(_ condition: Bool, _ what: String) {
        checks += 1
        if condition {
            print("[selfcheck] PASS  \(what)")
        } else {
            failures += 1
            print("[selfcheck] FAIL  \(what)")
        }
    }
}
#endif
