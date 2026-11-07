//
//  AppLanguageMode.swift
//  devkit
//
//  界面语言选项：跟随系统 / 简体中文 / English。
//  经 UserDefaults 的 `AppleLanguages` 键生效（重启应用后系统按此键选择 lproj）；
//  「跟随系统」= 移除该键，交回系统语言控制。语言名自标识（各语言下均显示「简体中文 / English」原文）。
//

import Foundation

enum AppLanguageMode: String, CaseIterable, Identifiable {
    case system = ""
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// 该语言对应的 lproj 目录名；`nil` = 跟随系统（不写 AppleLanguages）。
    var localizationCode: String? {
        switch self {
        case .system: return nil
        case .simplifiedChinese: return "zh-Hans"
        case .english: return "en"
        }
    }

    /// 选项标题。「跟随系统」是模式描述需要本地化（展示处经 L() 查表）；
    /// 「简体中文 / English」为语言自标识（惯例各语言下显示原文，不翻译）。
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    /// 把选择写入偏好：写 / 清 `AppleLanguages`，重启后生效。
    @MainActor
    func apply() {
        let defaults = UserDefaults.standard
        if let code = localizationCode {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }
}
