//
//  ContentView.swift
//  devkit
//
//  根视图：按 AppState.phase 路由到引导页 / 主壳 / 错误页。
//

import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    /// 外观模式（跟随系统 / 浅色 / 深色）：设置面板「通用」区写入，此处响应并全局生效。
    @AppStorage(AppPreferences.appearanceModeKey) private var appearanceRaw = AppAppearanceMode.system.rawValue

    var body: some View {
        Group {
            switch appState.phase {
            case .booting:
                BootingView()
            case .needsOnboarding:
                OnboardingView()
            case .ready:
                AppShellView()
            case .failed(let message):
                BootFailedView(message: message)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phaseKey)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 驱动 SwiftUI 环境的 colorScheme（终端容器据此在 updateNSView 刷新配色）。
        .preferredColorScheme(AppAppearanceMode.from(raw: appearanceRaw).colorScheme)
        // 同步设置 NSApp.appearance，让分离窗口与 AppKit 语义色一起切换。
        .onChange(of: appearanceRaw) { _, new in
            NSApp.appearance = AppAppearanceMode.from(raw: new).nsAppearance
        }
    }

    private var phaseKey: String {
        switch appState.phase {
        case .booting: return "booting"
        case .needsOnboarding: return "onboarding"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}

private struct BootingView: View {
    var body: some View {
        ZStack {
            VisualEffectBackground()
            ProgressView("正在启动 devkit…")
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BootFailedView: View {
    let message: String
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            VisualEffectBackground()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.yellow)
                Text("启动失败").font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                HStack(spacing: 12) {
                    Button("重试") {
                        Task { await appState.bootstrap() }
                    }
                    Button("重新选择数据目录…", role: .destructive) {
                        appState.resetDataDirectory()
                    }
                }
            }
            .padding(40)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState.shared)
}
