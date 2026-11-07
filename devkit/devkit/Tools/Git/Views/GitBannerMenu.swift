//
//  GitBannerMenu.swift
//  devkit
//
//  状态横幅的下拉选择按钮：真按钮触发（悬停高亮 + 手指光标 + 微动效），点击弹出原生 NSMenu
//  （勾选当前项、分区之间渲染分隔线）。分支 / 密钥 / 远程三处选择共用。
//
//  不用系统 Menu 做触发器：borderlessButton 样式没有悬停反馈；
//  不用自绘弹层（HTTPMethodPicker 式 overlay）：横幅内后面的兄弟视图（远程行 / 分区切换等）
//  z 序更高，会盖住向下溢出的面板——NSMenu 在独立菜单窗渲染，无此问题，且自带键盘导航。
//

import AppKit
import SwiftUI

/// 下拉选项：`title` 为 nil 表示分隔线（用于一组选项内部再分小节）。
struct GitBannerMenuOption {
    var title: String?
    var checked: Bool = false
    var action: (() -> Void)?

    /// 常规选项。
    init(title: String, checked: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.checked = checked
        self.action = action
    }

    /// 组内分隔线。
    static var divider: GitBannerMenuOption {
        GitBannerMenuOption(title: nil, checked: false, action: nil)
    }

    private init(title: String?, checked: Bool, action: (() -> Void)?) {
        self.title = title
        self.checked = checked
        self.action = action
    }
}

/// 下拉选择按钮。
///
/// `label` 闭包收到当前悬停态（Bool），需要自定义悬停样式的调用方（如密钥胶囊加深）
/// 可据此渲染，并可用 `showsHoverBackground` 关掉组件默认的悬停底色。
struct GitBannerMenu<Label: View>: View {
    /// 选项分区：相邻分区之间自动渲染分隔线（如密钥的「不绑定」与密钥列表）。
    let sections: [[GitBannerMenuOption]]
    var help: String = ""
    var isDisabled: Bool = false
    var showsHoverBackground: Bool = true
    @ViewBuilder var label: (Bool) -> Label

    @State private var isHovering = false

    init(options: [GitBannerMenuOption],
         help: String = "",
         isDisabled: Bool = false,
         showsHoverBackground: Bool = true,
         @ViewBuilder label: @escaping (Bool) -> Label) {
        self.sections = [options]
        self.help = help
        self.isDisabled = isDisabled
        self.showsHoverBackground = showsHoverBackground
        self.label = label
    }

    init(sections: [[GitBannerMenuOption]],
         help: String = "",
         isDisabled: Bool = false,
         showsHoverBackground: Bool = true,
         @ViewBuilder label: @escaping (Bool) -> Label) {
        self.sections = sections
        self.help = help
        self.isDisabled = isDisabled
        self.showsHoverBackground = showsHoverBackground
        self.label = label
    }

    var body: some View {
        Button(action: present) {
            label(isHovering)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering && showsHoverBackground
                              ? Theme.Palette.hoverOverlay
                              : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.micro, value: isHovering)
        .animation(Theme.Motion.micro, value: isDisabled)
        .pointingHandOnHover()
        .help(help)
    }

    /// 在点击位置弹出原生菜单（popUp 为模态，返回即已收起；targets 以局部数组撑住生命周期）。
    private func present() {
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView,
              let event = NSApp.currentEvent else { return }
        let menu = NSMenu()
        let targets = buildMenu(menu)
        let point = contentView.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: contentView)
        _ = targets   // 仅为延长 targets 生命周期至弹窗收起（NSMenuItem.target 弱引用）
    }

    private func buildMenu(_ menu: NSMenu) -> [MenuTarget] {
        var targets: [MenuTarget] = []
        for (sectionIndex, section) in sections.enumerated() {
            if sectionIndex > 0 { menu.addItem(.separator()) }
            for option in section {
                guard let title = option.title else {
                    menu.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if option.checked { item.state = .on }
                if let action = option.action {
                    let target = MenuTarget(action: action)
                    targets.append(target)
                    item.target = target
                    item.action = #selector(MenuTarget.invoke)
                } else if !option.checked {
                    item.isEnabled = false
                }
                menu.addItem(item)
            }
        }
        return targets
    }
}

/// 菜单项动作载体：NSMenuItem.target 为弱引用，需有强持有方（见 `GitBannerMenu.present`）。
private final class MenuTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() { action() }
}

/// 横幅小图标按钮（如远程行的铅笔）：与 GitBannerMenu 触发器同款悬停高亮。
struct BannerIconButton: View {
    let symbol: String
    var help: String = ""
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovering ? Theme.Palette.hoverOverlay : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.micro, value: isHovering)
        .pointingHandOnHover()
        .help(help)
    }
}
