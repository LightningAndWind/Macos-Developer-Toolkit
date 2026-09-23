//
//  AppAppearanceMode.swift
//  devkit
//
//  应用外观模式：跟随系统 / 浅色 / 深色。
//  偏好存 UserDefaults（键 `AppPreferences.appearanceModeKey`），由设置面板「通用」分区的开关写入。
//  生效走两条路径：① `NSApp.appearance` 统一整个 App（含分离窗口、AppKit 语义色）；
//  ② 根视图 `.preferredColorScheme` 驱动 SwiftUI 环境的 colorScheme。二者共同保证终端等 AppKit 视图随之外观切换。
//

import AppKit
import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 应用到 `NSApp.appearance` 的外观；nil 表示跟随系统。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// SwiftUI 层的 colorScheme 覆盖；跟随系统时为 nil（由系统决定）。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// 从存储的原始值解析；非法或缺失回退「跟随系统」。
    static func from(raw: String?) -> AppAppearanceMode {
        AppAppearanceMode(rawValue: raw ?? "") ?? .system
    }

    /// 读取当前偏好并应用到 `NSApp`（启动时与偏好变更时调用，跨窗口统一生效）。
    @MainActor
    static func applyCurrentToApp() {
        let raw = UserDefaults.standard.string(forKey: AppPreferences.appearanceModeKey)
        NSApp.appearance = AppAppearanceMode.from(raw: raw).nsAppearance
    }
}
