//
//  PanelHelpers.swift
//  devkit
//
//  AppKit 面板的 SwiftUI 便捷封装。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PanelHelpers {
    /// 弹出目录选择面板；取消返回 nil。
    @MainActor
    static func chooseDirectory(title: String,
                                prompt: String = "选择",
                                defaultURL: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = title
        panel.prompt = prompt
        panel.message = title
        if let defaultURL {
            panel.directoryURL = defaultURL
        } else if let home = FileManager.default.homeDirectoryForCurrentUser as URL? {
            panel.directoryURL = home.appendingPathComponent("Documents")
        }
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }

    /// 弹出保存文件面板（导出压缩包等）；覆盖既有文件由面板确认，取消返回 nil。
    @MainActor
    static func chooseSaveLocation(defaultFileName: String,
                                   title: String,
                                   prompt: String = "导出") -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFileName
        panel.allowedContentTypes = [.zip]
        panel.title = title
        panel.prompt = prompt
        panel.message = title
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 弹出 zip 文件选择面板（导入配置压缩包）；取消返回 nil。
    @MainActor
    static func chooseZipFile(title: String,
                              prompt: String = "导入") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.title = title
        panel.prompt = prompt
        panel.message = title
        return panel.runModal() == .OK ? panel.url : nil
    }
}
