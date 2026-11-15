//
//  L10n.swift
//  devkit
//
//  运行时本地化查找：以中文原文为 key 查主包 Localizable 表（String Catalog 编译产物），
//  查不到时回退 key 本身。用于 LocalizedStringKey 字面量自动本地化覆盖不到的纯 String 通道
//  （toast / 错误消息 / 枚举展示名 / NSAlert 标题 / 运行期拼接文案）——
//  混入的非 key 文本（如 git 命令英文输出）查不到即原样透传，无副作用。
//
//  含插值的文案统一写成显式格式串：String(format: L("第 %lld 行"), line)，
//  保证 catalog 中的 key 与源码字面量逐字一致（构建期不做自动提取）。
//

import Foundation

/// nonisolated：工程默认 MainActor 隔离会把全局函数也划入主 actor，
/// 而错误描述等 nonisolated 上下文（系统 ssh 传输层 / 压缩包服务等）同样要查表。
/// NSLocalizedString 本身线程安全，跨 actor 调用无副作用。
nonisolated func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
