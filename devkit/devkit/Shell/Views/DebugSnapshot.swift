//
//  DebugSnapshot.swift
//  devkit
//
//  调试专用（仅 DEBUG 编译）：把关键界面用 `ImageRenderer` 在进程内渲染成 PNG。
//
//  为什么需要它：本机没有授予「屏幕录制」权限，`screencapture` 一律失败
//  （`could not create image from window`，加 `dangerouslyDisableSandbox` 也一样）。
//  而 `ImageRenderer` 是进程内渲染、不碰窗口服务器，**不需要任何权限**，因此是
//  核对 UI 布局最可靠的手段。
//
//  用法：
//    DEVKIT_DATA_DIR=/tmp/x DEVKIT_SEED_DEMO=1 DEVKIT_SEED_COUNT=15 \
//    DEVKIT_SNAPSHOT=/tmp/shots <app>/Contents/MacOS/devkit
//  渲染完自动 `exit(0)`，不会留下窗口。
//
//  注意：`ImageRenderer` **不会触发** `onAppear` / `task`，所以依赖它们加载数据的视图
//  （如设置面板的列表）会以空态渲染 —— 面板骨架、导轨、按钮、空态提示仍可核对。
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum DebugSnapshot {
    static func runIfRequested(appState: AppState) {
        guard let raw = ProcessInfo.processInfo.environment["DEVKIT_SNAPSHOT"], !raw.isEmpty else { return }
        let base = URL(fileURLWithPath: raw, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let width = Theme.Metrics.sidebarWidth

        // ① 标签溢出：滚动区被裁切，底部固定条仍应留在最下方（用户关心的「标签滚动」）
        render(TabBarView().environment(appState),
               size: CGSize(width: width, height: 420),
               to: base.appendingPathComponent("01-sidebar-overflow.png"))

        // ② 侧栏最小宽度：齿轮按钮是否仍放得下、标题是否正常渐隐
        render(TabBarView().environment(appState),
               size: CGSize(width: Theme.Metrics.sidebarMinWidth, height: 300),
               to: base.appendingPathComponent("02-sidebar-min-width.png"))

        // ③ 侧栏标签行本体：用普通 VStack 承载**真实**的 TabItemView，
        //    绕开 ScrollView 限制，核对行内图标/标题/分组色条/“+”行。
        //    必须在下面「减到 2 个标签」之前渲染，否则行数不足。
        let coordinator = TabDragCoordinator()
        render(
            VStack(spacing: 0) {
                VStack(spacing: Theme.Metrics.tabGap) {
                    ForEach(appState.tabManager.tabs.prefix(5)) { tab in
                        TabItemView(tab: tab, coordinator: coordinator, liveFrames: [:])
                    }
                    NewTabButton()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Metrics.listPadding)
            .frame(width: Theme.Metrics.sidebarWidth)
            .background(.regularMaterial)
            .environment(appState),
            size: CGSize(width: Theme.Metrics.sidebarWidth, height: 220),
            to: base.appendingPathComponent("03-tab-rows.png"))

        // ④ 标签很少：固定条应贴在底部，而不是紧跟列表尾部
        while appState.tabManager.tabs.count > 2, let last = appState.tabManager.tabs.last {
            appState.tabManager.close(tabID: last.id)
        }
        render(TabBarView().environment(appState),
               size: CGSize(width: width, height: 560),
               to: base.appendingPathComponent("04-sidebar-short-list.png"))

        // ⑤ 设置面板骨架（列表为空态，见文件头说明）
        render(SettingsView().environment(appState),
               size: CGSize(width: 700, height: 480),
               to: base.appendingPathComponent("05-settings.png"))

        // ⑥ 探针：同一份内容分别放进 ScrollView 与普通 VStack，用来确认
        //    「ImageRenderer 不绘制 ScrollView 内容」这一限制（而非布局本身有问题）。
        render(
            HStack(spacing: 0) {
                ScrollView { probeContent }
                Divider()
                VStack(spacing: 6) { probeContent; Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white),
            size: CGSize(width: 320, height: 120),
            to: base.appendingPathComponent("06-scrollview-probe.png"))

        // ⑦ 设置面板记录行本体：同样绕开 ScrollView，核对方法徽标/标题/副标题/删除按钮。
        render(
            VStack(alignment: .leading, spacing: 4) {
                SettingsRecordRow(badge: "GET", badgeColor: HTTPDisplay.color(forMethod: "GET"),
                                  title: "用户接口", subtitle: "https://api.example.com/v1/users",
                                  deleteHelp: "删除该已保存请求", onDelete: {})
                SettingsRecordRow(badge: "POST", badgeColor: HTTPDisplay.color(forMethod: "POST"),
                                  title: "创建订单", subtitle: "https://api.example.com/v1/orders",
                                  deleteHelp: "删除该已保存请求", onDelete: {})
                SettingsRecordRow(badge: "DELETE", badgeColor: HTTPDisplay.color(forMethod: "DELETE"),
                                  title: "https://api.example.com/v1/users/7",
                                  subtitle: "17:38 · HTTP 404",
                                  deleteHelp: "删除该条历史", onDelete: {})
                SettingsRecordRow(symbol: "terminal", symbolColor: .accentColor,
                                  title: "生产服务器", subtitle: "root@10.0.0.5 · 生产环境",
                                  deleteHelp: "删除该连接", onDelete: {})
            }
            .padding(10)
            .frame(width: 440)
            .background(Color.white),
            size: CGSize(width: 440, height: 226),
            to: base.appendingPathComponent("07-settings-rows.png"))

        // ⑧ 响应区被截断时：状态条应带「≥」大小前缀，下方应出现截断提示条。
        //    状态条与提示条都在 ScrollView **之外**，所以 ImageRenderer 画得出来；
        //    内容区（ScrollView）会是空白 —— 本轮只核对这两处。
        //    响应体特意用非 UTF-8 字节（0xFF），让内容区走 binaryHint，
        //    而不是把 10 MB 文本交给 `Text` 渲染（那会拖死渲染器）。
        let truncatedTool = HTTPTool()
        truncatedTool.response = HTTPResponseModel(
            statusCode: 200,
            headers: [(key: "Content-Type", value: "application/octet-stream")],
            bodyData: Data(repeating: 0xFF, count: HTTPClient.maxBodyBytes),
            durationMs: 1_240,
            isBodyTruncated: true
        )
        render(ResponseViewerView(tool: truncatedTool).background(Color.white),
               size: CGSize(width: 620, height: 240),
               to: base.appendingPathComponent("08-response-truncated.png"))

        // ⑨ 对照组：完整响应不应出现提示条，大小也不该带「≥」前缀。
        let wholeTool = HTTPTool()
        wholeTool.response = HTTPResponseModel(
            statusCode: 200,
            headers: [(key: "Content-Type", value: "application/json")],
            bodyData: Data(#"{"ok":true,"items":[1,2,3]}"#.utf8),
            durationMs: 86,
            isBodyTruncated: false
        )
        render(ResponseViewerView(tool: wholeTool).background(Color.white),
               size: CGSize(width: 620, height: 240),
               to: base.appendingPathComponent("09-response-whole.png"))

        exit(0)
    }

    /// 探针内容：左（ScrollView 内）与右（普通 VStack）各一份，肉眼对比即可判断限制。
    private static var probeContent: some View {
        VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Text("行 \(i + 1)")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.18)))
            }
        }
        .padding(6)
    }

    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("[snapshot] 渲染失败：\(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
        print("[snapshot] \(url.path)  \(Int(size.width))x\(Int(size.height))")
    }
}
#endif
