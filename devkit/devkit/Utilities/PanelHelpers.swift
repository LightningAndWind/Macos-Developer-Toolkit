//
//  PanelHelpers.swift
//  devkit
//
//  AppKit 面板的 SwiftUI 便捷封装。
//

import AppKit
import SwiftUI

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
}
