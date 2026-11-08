//
//  SidebarWidthState.swift
//  devkit
//
//  侧栏宽度状态：档位 + 超窄开关（持久化）+ 目标宽度。宽度过渡的插值由主界面驱动。
//

import SwiftUI

/// 侧栏宽度状态。主界面与标签栏宽度按钮共用同一实例。
///
/// 为什么不用 `@AppStorage`：主界面与标签栏各自持有 @AppStorage 时，跨视图同步发生在
/// 点击事务之外；收进一个可观察对象后两处读同一份状态，天然同步，持久化 didSet 也集中在此。
///
/// 宽度过渡的分工（实现见 AppShellView）：**内容区不参与动画** —— 占位直接落 `targetWidth`
/// 一次重排到位；隐藏的常驻标签由 ResidentTabSlot 冻结尺寸、不参与该次重排
/// （否则隐藏终端 NSTextView 的全量 rewrap 全压在点击帧上，切档卡顿明显）。
/// 因此只让侧栏视觉层插值滑动，由主界面监听 `targetWidth` 变化后显式驱动。
@MainActor
@Observable
final class SidebarWidthState {
    /// 展开态宽度档位（持久化）。
    var widthMode: Theme.SidebarWidthMode = .standard {
        didSet {
            guard widthMode != oldValue else { return }
            defaults.set(widthMode.rawValue, forKey: AppPreferences.sidebarWidthModeKey)
        }
    }

    /// 超窄模式（标准档一半宽度，样式不变，持久化）。
    var isCollapsed = false {
        didSet {
            guard isCollapsed != oldValue else { return }
            defaults.set(isCollapsed, forKey: AppPreferences.sidebarCollapsedKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let mode = Theme.SidebarWidthMode(rawValue: defaults.integer(forKey: AppPreferences.sidebarWidthModeKey)) ?? .standard
        let collapsed = defaults.bool(forKey: AppPreferences.sidebarCollapsedKey)
        self.widthMode = mode
        self.isCollapsed = collapsed
    }

    /// 目标宽度：内容区占位直接落位的目标，也是侧栏视觉层过渡的终点。
    var targetWidth: CGFloat {
        isCollapsed ? Theme.Metrics.sidebarUltraNarrowWidth : widthMode.width
    }

    /// 切换到指定档位（并退出超窄）。
    ///
    /// 档位、开关在同一次写入里完成，主界面与标签栏按钮天然同步。
    /// 宽度本身不做动画（理由见类型注释）；先落档位再退出超窄，
    /// 保证宽度从超窄一步到目标档。
    func select(_ mode: Theme.SidebarWidthMode) {
        guard widthMode != mode || isCollapsed else { return }
        widthMode = mode
        isCollapsed = false
    }

    /// 切换超窄 / 恢复展开。超窄态恢复一律回「标准宽度」档：回到一个确定、可预期的状态，
    /// 比记住历史档位更直观（先落档位再展开，宽度一步到位，不做两段动画）。
    func toggleCollapsed() {
        if isCollapsed {
            widthMode = .standard
            isCollapsed = false
        } else {
            isCollapsed = true
        }
    }
}
