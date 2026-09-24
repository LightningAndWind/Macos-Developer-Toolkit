//
//  SheetProbe.swift
//  devkit
//
//  临时诊断（仅 DEBUG，验证后移除）：自动弹出 SSH 选择器 sheet，
//  用进程内 `cacheDisplay` 把所有窗口渲染成 PNG —— 不依赖「屏幕录制」权限。
//
//  用法：DEVKIT_DATA_DIR=/tmp/probe DEVKIT_SHEET_PROBE=/tmp/shots <app>/Contents/MacOS/devkit
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum SheetProbe {
    static func runIfRequested(appState: AppState) {
        guard let raw = ProcessInfo.processInfo.environment["DEVKIT_SHEET_PROBE"], !raw.isEmpty else { return }
        let base = URL(fileURLWithPath: raw, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // 造 20 个连接配置：保证选择器 220pt 的树溢出（指示条才该出现）。
        for i in 0..<20 {
            let p = SSHProfile(folderID: nil, name: "服务器-\(String(format: "%02d", i))",
                               host: "10.0.0.\(i)", port: 22, username: "root", authKind: .password)
            try? SSHProfileStore.save(p)
        }
        print("[sheet-probe] 已写入 20 个 SSH profile")

        // 开一个 SSH 标签并弹出选择器 sheet。
        guard let d = ToolRegistry.shared.descriptor(for: "tool.ssh"),
              let tab = appState.tabManager.openTool(descriptor: d) else {
            print("[sheet-probe] 无法打开 SSH 标签")
            exit(3)
        }
        appState.tabManager.select(tab.id)
        appState.sshChooserTabID = tab.id
        print("[sheet-probe] 已请求弹出 SSH 选择器，2.5s 后截图…")

        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            for (idx, win) in NSApp.windows.enumerated() {
                guard let content = win.contentView else { continue }
                let bounds = content.bounds
                guard bounds.width > 1, bounds.height > 1,
                      let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
                content.cacheDisplay(in: bounds, to: rep)
                guard let tiff = rep.tiffRepresentation,
                      let out = NSBitmapImageRep(data: tiff),
                      let png = out.representation(using: .png, properties: [:]) else { continue }
                let kind = win.styleMask.contains(.titled) ? "titled" : "untitled"
                let url = base.appendingPathComponent("window-\(idx)-\(kind)-\(Int(bounds.width))x\(Int(bounds.height)).png")
                try? png.write(to: url)
                print("[sheet-probe] \(url.path)")
            }
            exit(0)
        }
    }
}
#endif
