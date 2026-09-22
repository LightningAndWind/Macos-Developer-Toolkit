//
//  devkitApp.swift
//  devkit
//
//  App 入口：注册工具、装配 AppState、路由引导/主界面。
//

import SwiftUI
import AppKit

@main
struct devkitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState = .shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ToolRegistration.registerAll()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task {
                    await appState.bootstrap()
                }
                .onChange(of: scenePhase) { _, new in
                    if new == .inactive || new == .background {
                        appState.saveSession()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            DevkitCommands(appState: appState)
        }
    }
}

/// 应用生命周期兜底：正常退出（⌘Q）前立即落盘会话，取消挂起的防抖任务确保写入最新状态。
/// 开发重编译/强杀不走此钩子，由 HTTPToolView 的内容变更防抖保存兜底。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.saveSession()
        }
    }
}
