//
//  DevkitCommands.swift
//  devkit
//
//  菜单栏命令与快捷键：⌘T 新标签、⌘W 关闭、⌘1~9 直达、⌃Tab 切换、⌘E 重命名。
//

import SwiftUI

struct DevkitCommands: Commands {
    @Bindable var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新标签") {
                appState.tabManager.isLauncherPresented = true
                appState.tabManager.selectedTabID = nil
            }
            .keyboardShortcut("t", modifiers: .command)

            Divider()

            // ⌘1 ~ ⌘9 直达标签；⌘0 最后一个
            ForEach(1...9, id: \.self) { idx in
                Button("跳转到第 \(idx) 个标签") {
                    appState.tabManager.selectAt(position: idx)
                    appState.saveSession()
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx)")), modifiers: .command)
            }
            Button("跳转到最后一个标签") {
                appState.tabManager.selectAt(position: 0)
                appState.saveSession()
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("关闭标签") {
                if let id = appState.tabManager.selectedTabID {
                    if appState.tabManager.selectedTab?.toolInstance?.hasUnsavedContent == true {
                        appState.pendingCloseTabID = id
                    } else {
                        appState.closeTab(id)
                    }
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("切换到下一个标签") {
                appState.tabManager.selectNext()
            }
            .keyboardShortcut(.downArrow, modifiers: .control)

            Button("切换到上一个标签") {
                appState.tabManager.selectPrevious()
            }
            .keyboardShortcut(.upArrow, modifiers: .control)
        }

        CommandMenu("标签") {
            Button("重命名当前标签…") {
                // 通过 NSAlert 输入框简化处理，TabItemView 也支持双击重命名。
                guard let tab = appState.tabManager.selectedTab else { return }
                let alert = NSAlert()
                alert.messageText = "重命名标签"
                alert.addButton(withTitle: "确定")
                alert.addButton(withTitle: "取消")
                let tf = NSTextField(string: tab.displayTitle)
                tf.frame.size.width += 80
                alert.accessoryView = tf
                if alert.runModal() == .alertFirstButtonReturn {
                    appState.tabManager.rename(tabID: tab.id, to: tf.stringValue)
                    appState.saveSession()
                }
            }
            .keyboardShortcut("e", modifiers: .command)

            Divider()

            Button("将当前标签移入新分组…") {
                guard let tab = appState.tabManager.selectedTab else { return }
                let color = TabGroup.GroupColor.allCases[
                    Int.random(in: 0..<TabGroup.GroupColor.allCases.count)
                ]
                appState.tabManager.createGroup(with: [tab.id], name: "分组", color: color)
                appState.saveSession()
            }
            Button("将当前标签移出分组") {
                guard let tab = appState.tabManager.selectedTab else { return }
                appState.tabManager.move(tabID: tab.id, to: nil)
                appState.saveSession()
            }
        }

        CommandGroup(after: .appSettings) {
            Button("重置数据目录…") {
                appState.resetDataDirectory()
            }
        }
    }
}
