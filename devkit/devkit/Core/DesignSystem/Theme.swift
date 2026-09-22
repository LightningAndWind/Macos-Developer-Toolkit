//
//  Theme.swift
//  devkit
//
//  集中式设计令牌（Design Tokens）。所有尺寸、间距、动画曲线统一在此定义，
//  避免散落的魔法数字，保证视觉一致性（单一数据源原则）。
//

import SwiftUI

/// 全局设计系统。按维度拆分子命名空间，纯静态、无状态。
enum Theme {

    /// 尺寸与间距令牌。
    enum Metrics {
        /// 左侧竖向标签栏（侧栏）默认宽度；实际宽度由用户拖拽分割线调整并持久化。
        static let sidebarWidth: CGFloat = 208
        /// 侧栏最小宽度：约为默认宽度一半，且比左上角三色按钮（约 80pt）略宽，保证按钮不溢出。
        static let sidebarMinWidth: CGFloat = 108
        /// 侧栏最大宽度：再宽会明显挤压内容区，收益递减。
        static let sidebarMaxWidth: CGFloat = 360
        /// 分割线拖拽热区宽度（视觉仍为 1pt 细线，仅热区加宽）。
        static let splitterHitWidth: CGFloat = 7
        /// 横向分割线（上下分区）拖拽热区高度；视觉仍为 1pt 细线，仅热区加高。
        static let splitterHitHeight: CGFloat = 7
        /// HTTP 请求编辑区 / 响应区各自的最小高度：拖拽分隔线时任一区域不得压缩到此值以下。
        static let httpPaneMinHeight: CGFloat = 120
        /// 标题尾部渐隐长度：文字超出可展示宽度时，最后这段距离内淡出消失（不用省略号）。
        static let titleFadeLength: CGFloat = 18
        /// 标签标题单行行高（12pt 系统字体），用于固定渐隐文本容器高度，避免 GeometryReader 纵向贪婪。
        static let titleLineHeight: CGFloat = 16
        /// 侧栏顶部预留高度：容纳左上角三色按钮 + “+” 按钮。
        static let sidebarHeaderHeight: CGFloat = 38
        /// 单个标签行高度。
        static let tabRowHeight: CGFloat = 30
        /// 标签行圆角。
        static let tabCornerRadius: CGFloat = 7
        /// 标签内图标与文字间距。
        static let tabInnerSpacing: CGFloat = 8
        /// 标签行之间的竖向间距。
        static let tabGap: CGFloat = 4
        /// 标签行左右内边距。
        static let tabHPadding: CGFloat = 10
        /// 侧栏列表内边距。
        static let listPadding: CGFloat = 8
        /// 分组左侧色条宽度。
        static let groupAccentWidth: CGFloat = 3
        /// 自绘滚动指示条宽度（轨道与指示条同宽）。
        static let scrollIndicatorWidth: CGFloat = 4
        /// 滚动指示条距侧栏右缘（分割线）的距离；位于列表内边距之外，避免与标签行重合。
        static let scrollIndicatorTrailing: CGFloat = 2
        /// 滚动轨道上下内边距。
        static let scrollIndicatorVPadding: CGFloat = 4
        /// 点击与拖拽的区分阈值：统一手势（minimumDistance 0）中位移超过此值才视为拖拽，否则当作点击。
        static let dragMinimumDistance: CGFloat = 3
        /// 浮动预览相对中心跟随指针的水平最大偏移（防止溢出侧栏）。
        static let dragMaxHorizontalShift: CGFloat = 18
    }

    /// 字体令牌。
    enum Fonts {
        static let tabTitle = Font.system(size: 12)
        static let tabSymbol = Font.system(size: 11)
        static let badge = Font.system(size: 10)
    }

    /// 动画令牌（统一曲线，保证交互手感一致）。
    enum Motion {
        /// 选中态、悬停等微交互。
        static let micro: Animation = .easeOut(duration: 0.14)
        /// 标签增删、布局变化。
        static let layout: Animation = .spring(response: 0.32, dampingFraction: 0.82)
        /// 内容切换。
        static let content: Animation = .easeInOut(duration: 0.22)
        /// 拖拽时其他标签的避让位移：高阻尼、短响应，跟手不拖泥带水。
        static let drag: Animation = .spring(response: 0.22, dampingFraction: 0.9)
    }

    /// 转场令牌（视图插入 / 移除动画）。
    enum Transitions {
        /// 标签行：插入时淡入+左移，移除时淡出。
        static let tabItem: AnyTransition = .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .leading)),
            removal: .opacity
        )
        /// 分组行。
        static let chip: AnyTransition = .opacity
        /// 下拉弹层：自顶部锚点淡入并轻微展开，收起时仅淡出（“渐入渐出”）。
        static let dropdown: AnyTransition = .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
            removal: .opacity
        )
    }

    /// 颜色令牌。
    enum Palette {
        /// 选中标签背景。
        static let tabSelected = Color.primary.opacity(0.11)
        /// 未选中标签背景。
        static let tabIdle = Color.primary.opacity(0.04)
        /// 悬停叠加层。
        static let hoverOverlay = Color.primary.opacity(0.06)
        /// 选中描边。
        static let accentStroke = Color.accentColor.opacity(0.65)
        /// 滚动轨道背景：比侧栏背景稍深、比指示条稍浅，暗示可滚动范围。
        static let scrollTrack = Color.primary.opacity(0.10)
        /// 滚动指示条。
        static let scrollKnob = Color.primary.opacity(0.28)
        /// 拖拽时留在原位的“残影”占位行透明度。
        static let dragGhostOpacity: Double = 0.15
        /// 侧栏与内容区之间的分割线。
        static let splitter = Color(nsColor: .separatorColor)
        /// 拖拽 / 悬停分割线时的高亮色，提示“此处可拖动调宽”。
        static let splitterActive = Color.accentColor.opacity(0.75)
        /// 浮动拖拽预览的阴影。
        static let dragShadow = Color.black.opacity(0.20)
    }
}
