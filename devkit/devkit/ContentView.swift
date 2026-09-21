//
//  ContentView.swift
//  devkit
//
//  根视图：按 AppState.phase 路由到引导页 / 主壳 / 错误页。
//

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

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
