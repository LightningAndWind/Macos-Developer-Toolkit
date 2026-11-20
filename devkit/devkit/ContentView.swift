//
//  ContentView.swift
//  devkit
//
//  根视图：按 AppState.phase 路由到启动页 / 主壳 / 错误页。
//

import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    /// 外观模式（跟随系统 / 浅色 / 深色）：设置面板「通用」区写入，此处响应并全局生效。
    @AppStorage(AppPreferences.appearanceModeKey) private var appearanceRaw = AppAppearanceMode.system.rawValue
    /// 简约模式（去透明 + 黑白灰）：与明暗外观正交，经环境值下发驱动全树。
    @AppStorage(AppPreferences.minimalModeKey) private var minimalMode = false

    init() {
        // 首帧前把旗标同步给调色板计算型令牌（accent 等），避免第一拍渲染出旧配色。
        // 运行期切换由设置面板的 Toggle setter 先写旗标再写存储，此处 onChange 仅作兜底。
        Theme.minimalMode = UserDefaults.standard.bool(forKey: AppPreferences.minimalModeKey)
    }

    var body: some View {
        Group {
            switch appState.phase {
            case .booting:
                BootingView()
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
        // 简约模式下发：环境值可穿透常驻标签的 .equatable() 屏障，精准失效读取它的视图。
        .environment(\.minimalMode, minimalMode)
        // 根 tint：简约时控件（复选框 / 分段选择器 / 默认按钮）一并灰化；非简约等于系统强调色。
        .tint(Theme.Palette.accent)
        // 同步设置 NSApp.appearance，让分离窗口与 AppKit 语义色一起切换。
        .onChange(of: appearanceRaw) { _, new in
            NSApp.appearance = AppAppearanceMode.from(raw: new).nsAppearance
        }
        // 兜底同步（正常路径是设置 Toggle 先写旗标）：外部改动偏好键时保持一致。
        .onChange(of: minimalMode) { _, new in
            Theme.minimalMode = new
        }
    }

    private var phaseKey: String {
        switch appState.phase {
        case .booting: return "booting"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}

private struct BootingView: View {
    @Environment(\.minimalMode) private var minimalMode

    var body: some View {
        ZStack {
            if minimalMode {
                Color(nsColor: .windowBackgroundColor)
            } else {
                VisualEffectBackground()
            }
            ProgressView("正在启动 devkit…")
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BootFailedView: View {
    let message: String
    @Environment(AppState.self) private var appState
    @Environment(\.minimalMode) private var minimalMode

    var body: some View {
        ZStack {
            if minimalMode {
                Color(nsColor: .windowBackgroundColor)
            } else {
                VisualEffectBackground()
            }
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.yellow)
                Text("启动失败").font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("重试") {
                    Task { await appState.bootstrap() }
                }
            }
            .padding(40)
        }
    }
}

/// 使用 NSVisualEffectView 提供原生毛玻璃背景。
/// （原在 OnboardingView.swift；引导页移除后收编到这里，AppShellView 仍在使用。）
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // 只在真的变化时写：宿主视图任何一次重算都会走到这里，无条件赋值会让
        // NSVisualEffectView 反复失效重绘（侧栏拖拽时尤其明显）。
        if nsView.material != material { nsView.material = material }
        if nsView.blendingMode != blendingMode { nsView.blendingMode = blendingMode }
    }
}

#Preview {
    ContentView()
        .environment(AppState.shared)
}
