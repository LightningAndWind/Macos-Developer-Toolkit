//
//  devkitApp.swift
//  devkit
//
//  App 入口：注册工具、装配 AppState、路由引导/主界面。
//

import SwiftUI

@main
struct devkitApp: App {
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
