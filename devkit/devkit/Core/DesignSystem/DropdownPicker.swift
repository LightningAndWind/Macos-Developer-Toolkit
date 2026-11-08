//
//  DropdownPicker.swift
//  devkit
//
//  通用下拉选择框（自绘弹层）：触发器（悬停高亮 + 手指光标）点击后，在触发器正下方贴边弹出
//  选项面板 —— 勾选当前项、悬停高亮、分区分隔线；点面板外任意处收起。
//  取代 GitBannerMenu 时代的 NSMenu.popUp：浮动菜单窗与触发器位置脱节、样式不可控，
//  自绘面板宽度按最长选项自适应、贴近窗口下沿时自动向上翻转。
//
//  层级注意：面板溢出触发器所在容器，若同容器的后续兄弟视图（下方的行 / 分区）会盖住面板，
//  调用方须给触发器所在行/区加 zIndex，或用 onPresentedChange 在展开时抬升所在行
//  （见 GitRepoDetailView 横幅、DBToolView 顶栏、SettingsView 仓库行的用法）。
//

import AppKit
import SwiftUI

/// 下拉选项：`title` 为 nil 表示分隔线（用于一组选项内部再分小节）。
struct DropdownOption {
    var title: String?
    /// 行尾次要说明（如数据库连接的类型标注）。
    var detail: String?
    var checked: Bool = false
    var action: (() -> Void)?

    /// 常规选项。
    init(title: String, detail: String? = nil, checked: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.detail = detail
        self.checked = checked
        self.action = action
    }

    /// 组内分隔线。
    static var divider: DropdownOption {
        DropdownOption(title: nil, detail: nil, checked: false, action: nil)
    }

    private init(title: String?, detail: String?, checked: Bool, action: (() -> Void)?) {
        self.title = title
        self.detail = detail
        self.checked = checked
        self.action = action
    }
}

/// 下拉选择框。
///
/// `label` 闭包收到当前悬停态（Bool），需要自定义悬停样式的调用方（如密钥胶囊加深）
/// 可据此渲染，并可用 `showsHoverBackground` 关掉组件默认的悬停底色；
/// `alignsTrailing` 让面板沿触发器右缘向左展开（触发器贴近窗口右缘时用）。
struct DropdownPicker<Label: View>: View {
    /// 选项分区：相邻分区之间自动渲染分隔线（如密钥的「不绑定」与密钥列表）。
    let sections: [[DropdownOption]]
    var help: String = ""
    var isDisabled: Bool = false
    var showsHoverBackground: Bool = true
    var alignsTrailing: Bool = false
    /// 面板宽度上限：调用方可收紧，让弹层不越出自己所在容器的横向范围（默认 460）。
    var maxPanelWidth: CGFloat = DropdownPickerLayout.maxPanelWidth
    /// 展开态变化回调（调用方据此给所在行加 zIndex，避免面板被后续兄弟视图盖住）。
    var onPresentedChange: ((Bool) -> Void)?
    /// 选中项的动作延后到弹层收起动画结束之后再执行（默认关闭）。
    ///
    /// 动作常伴随重活（如记事本切分类要重建整列列表）：与收起动画同帧发生时主线程被占满，
    /// 收起动画的首帧被推迟、动画时钟在恢复后已走完 —— 弹层看起来就是卡一下然后瞬间消失。
    /// 打开此项则先让弹层把动画跑完，再执行动作。
    var defersActionUntilDismissed: Bool = false
    @ViewBuilder var label: (Bool) -> Label

    @State private var isHovering = false
    @State private var isPresented = false
    /// 空间不足时向上翻转（点击时按窗口剩余空间判定）。
    @State private var opensUpward = false

    init(options: [DropdownOption],
         help: String = "",
         isDisabled: Bool = false,
         showsHoverBackground: Bool = true,
         alignsTrailing: Bool = false,
         maxPanelWidth: CGFloat = DropdownPickerLayout.maxPanelWidth,
         onPresentedChange: ((Bool) -> Void)? = nil,
         defersActionUntilDismissed: Bool = false,
         @ViewBuilder label: @escaping (Bool) -> Label) {
        self.sections = [options]
        self.help = help
        self.isDisabled = isDisabled
        self.showsHoverBackground = showsHoverBackground
        self.alignsTrailing = alignsTrailing
        self.maxPanelWidth = maxPanelWidth
        self.onPresentedChange = onPresentedChange
        self.defersActionUntilDismissed = defersActionUntilDismissed
        self.label = label
    }

    init(sections: [[DropdownOption]],
         help: String = "",
         isDisabled: Bool = false,
         showsHoverBackground: Bool = true,
         alignsTrailing: Bool = false,
         maxPanelWidth: CGFloat = DropdownPickerLayout.maxPanelWidth,
         onPresentedChange: ((Bool) -> Void)? = nil,
         defersActionUntilDismissed: Bool = false,
         @ViewBuilder label: @escaping (Bool) -> Label) {
        self.sections = sections
        self.help = help
        self.isDisabled = isDisabled
        self.showsHoverBackground = showsHoverBackground
        self.alignsTrailing = alignsTrailing
        self.maxPanelWidth = maxPanelWidth
        self.onPresentedChange = onPresentedChange
        self.defersActionUntilDismissed = defersActionUntilDismissed
        self.label = label
    }

    var body: some View {
        trigger
            .background(scrim)
            .overlay(alignment: panelAlignment) { panel }
            .onExitCommand { close() }
    }

    // MARK: - 触发器

    private var trigger: some View {
        Button(action: toggle) {
            label(isHovering)
                .padding(.horizontal, 6)
                .frame(height: DropdownPickerLayout.triggerHeight)
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

    // MARK: - 弹层

    private var panelAlignment: Alignment {
        if opensUpward { return alignsTrailing ? .bottomTrailing : .bottomLeading }
        return alignsTrailing ? .topTrailing : .topLeading
    }

    /// 选项列表；超高时进滚动视图（高度固定，行高均为定值，可精确计算是否溢出）。
    @ViewBuilder
    private var list: some View {
        if rowsHeight > DropdownPickerLayout.maxVisibleHeight {
            ScrollView { rows }
                .scrollIndicators(.never)
                .frame(height: DropdownPickerLayout.maxVisibleHeight)
        } else {
            rows
        }
    }

    /// 选项行 + 分隔线（分区之间自动渲染分隔线）。
    private var rows: some View {
        VStack(spacing: DropdownPickerLayout.itemSpacing) {
            ForEach(sections.indices, id: \.self) { sectionIndex in
                if sectionIndex > 0 { dividerRow }
                ForEach(sections[sectionIndex].indices, id: \.self) { index in
                    rowOrDivider(sections[sectionIndex][index])
                }
            }
        }
    }

    @ViewBuilder
    private func rowOrDivider(_ option: DropdownOption) -> some View {
        if let title = option.title {
            DropdownPickerItem(option: option, panelWidth: panelWidth) {
                select(option)
            }
        } else {
            dividerRow
        }
    }

    /// 选中一项。
    ///
    /// 默认先执行动作再收起弹层；`defersActionUntilDismissed` 为真时改为先收起、
    /// 等收起动画跑完再执行动作（见该属性的说明）。
    private func select(_ option: DropdownOption) {
        guard defersActionUntilDismissed else {
            option.action?()
            close()
            return
        }
        close()
        Task { @MainActor in
            try? await Task.sleep(for: DropdownPickerLayout.dismissDelay)
            option.action?()
        }
    }

    private var dividerRow: some View {
        Divider().padding(.vertical, 4)
    }

    @ViewBuilder
    private var panel: some View {
        if isPresented {
            VStack(spacing: 0) {
                if !opensUpward { spacerBelowTrigger }
                list
                    .padding(DropdownPickerLayout.panelPadding)
                    .frame(width: panelWidth)
                    .background(panelBackground)
                if opensUpward { spacerBelowTrigger }
            }
            .transition(panelTransition)
        }
    }

    /// 缩放锚点：下弹从触发器上沿展开，上翻从下沿展开。
    private var panelAnchor: UnitPoint { opensUpward ? .bottom : .top }

    /// 弹层转场：展开 / 收起对称（淡入淡出 + 轻微缩放）。
    /// 收起时若只做淡出，大面积近实心面板会“啪”地一下消失，观感生硬；
    /// 让淡出同时向锚点收拢，和展开是一个动作的两个方向。
    private var panelTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: panelAnchor)),
            removal: .opacity.combined(with: .scale(scale: 0.94, anchor: panelAnchor)))
    }

    /// 与触发器等高的透明占位 + 间距：把选项列表顶到触发器之外（下弹占上方、上翻占下方）。
    private var spacerBelowTrigger: some View {
        Color.clear.frame(height: DropdownPickerLayout.triggerHeight + DropdownPickerLayout.gapBelowTrigger)
    }

    /// 面板底：近实心的 windowBackgroundColor（92%）叠在 thickMaterial 上 ——
    /// 只留一点点毛玻璃质感，后面元素不透出、也点不到（纯 material 太透，实测会与背景内容混在一起）。
    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            .shadow(color: Theme.Palette.dragShadow, radius: 10, x: 0, y: 5)
    }

    /// 透明挡板：吃掉弹层之外的点击，点任意处即收起。
    @ViewBuilder
    private var scrim: some View {
        if isPresented {
            Color.clear
                .frame(width: DropdownPickerLayout.scrimSize, height: DropdownPickerLayout.scrimSize)
                .contentShape(Rectangle())
                .onTapGesture { close() }
        }
    }

    // MARK: - 尺寸与朝向

    /// 面板宽度：按最长选项文本自适应（标题 12pt / 说明 10pt），并夹在 [180, maxPanelWidth]。
    private var panelWidth: CGFloat {
        let titleFont = NSFont.systemFont(ofSize: 12)
        let detailFont = NSFont.systemFont(ofSize: 10)
        var maxRowWidth: CGFloat = 0
        for option in sections.flatMap({ $0 }) {
            guard let title = option.title else { continue }
            var width = (title as NSString).size(withAttributes: [.font: titleFont]).width
            if let detail = option.detail {
                width += 12 + (detail as NSString).size(withAttributes: [.font: detailFont]).width
            }
            maxRowWidth = max(maxRowWidth, width)
        }
        // 余量：勾选槽 12 + 间距 6 + 行水平内边距 12 + 面板内边距 12 + 富余 8。
        return min(maxPanelWidth, max(DropdownPickerLayout.minPanelWidth, ceil(maxRowWidth) + 50))
    }

    /// 选项区自然高度（行高均为定值，可精确累加；不含面板内边距）。
    private var rowsHeight: CGFloat {
        var height: CGFloat = 0
        var count = 0
        for (sectionIndex, section) in sections.enumerated() {
            if sectionIndex > 0 {
                height += DropdownPickerLayout.dividerHeight
                count += 1
            }
            for option in section {
                height += option.title == nil ? DropdownPickerLayout.dividerHeight : DropdownPickerLayout.itemHeight
                count += 1
            }
        }
        if count > 1 { height += DropdownPickerLayout.itemSpacing * CGFloat(count - 1) }
        return height
    }

    /// 点击时按窗口剩余空间判定是否向上翻转：下方放不下整个面板（列表 + 内边距 + 触发器占位 + 余量）
    /// 且上方空间更大时才上翻；上下都放不下保持向下（触发器与面板首行仍可见）。
    /// 坐标系注意：SwiftUI 宿主的 contentView（NSHostingView）是**翻转系**（y 向下增长），
    /// 点位 y = 距窗口顶部距离，下方剩余 = maxY - y；非翻转系（AppKit 常规）y 向上增长，下方剩余 = y - minY。
    /// 判反了会导致顶部触发器永远判定"下方空间不足"而永远上翻（实测踩过）。
    private func computeOpensUpward() -> Bool {
        guard let event = NSApp.currentEvent,
              let window = event.window ?? NSApp.keyWindow,
              let contentView = window.contentView else { return false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let roomBelow: CGFloat
        let roomAbove: CGFloat
        if contentView.isFlipped {
            roomBelow = contentView.bounds.maxY - point.y
            roomAbove = point.y - contentView.bounds.minY
        } else {
            roomBelow = point.y - contentView.bounds.minY
            roomAbove = contentView.bounds.maxY - point.y
        }
        let needed = min(rowsHeight, DropdownPickerLayout.maxVisibleHeight)
            + DropdownPickerLayout.panelPadding * 2
            + DropdownPickerLayout.triggerHeight + DropdownPickerLayout.gapBelowTrigger
            + DropdownPickerLayout.windowMargin
        return roomBelow < needed && roomAbove > roomBelow
    }

    // MARK: - 交互

    private func toggle() {
        if isPresented { close() } else { open() }
    }

    private func open() {
        opensUpward = computeOpensUpward()
        withAnimation(Theme.Motion.content) { isPresented = true }
        onPresentedChange?(true)
    }

    private func close() {
        guard isPresented else { return }
        withAnimation(Theme.Motion.content) { isPresented = false }
        // 抬升态（zIndex）延后回落：立刻回落会让仍在淡出的弹层被后续兄弟视图盖住，
        // 看起来就像瞬间消失。若期间重新展开，则保持抬升（open() 已立即抬升）。
        Task { @MainActor in
            try? await Task.sleep(for: DropdownPickerLayout.dismissDelay)
            guard !isPresented else { return }
            onPresentedChange?(false)
        }
    }
}

/// 面板尺寸令牌（泛型类型内不允许静态存储属性，提到文件级）。
private enum DropdownPickerLayout {
    static let triggerHeight: CGFloat = 22
    static let gapBelowTrigger: CGFloat = 4
    static let itemHeight: CGFloat = 24
    static let itemSpacing: CGFloat = 2
    /// 分隔线高度（Divider 1pt + 上下各 4pt）。
    static let dividerHeight: CGFloat = 9
    static let panelPadding: CGFloat = 6
    static let minPanelWidth: CGFloat = 180
    static let maxPanelWidth: CGFloat = 460
    static let maxVisibleHeight: CGFloat = 320
    static let scrimSize: CGFloat = 4_000
    static let windowMargin: CGFloat = 12
    /// 收起动画结束后再回落调用方的 zIndex（略长于 `Theme.Motion.content` 的 0.22s）。
    static let dismissDelay: Duration = .milliseconds(240)
}

/// 面板中的单个选项行：勾选槽 + 标题（+ 行尾次要说明），悬停浅色高亮；
/// 无动作且未勾选的行渲染为禁用态（如「暂无连接」占位）。
private struct DropdownPickerItem: View {
    let option: DropdownOption
    let panelWidth: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    /// 有动作、或当前勾选项（点击仅收起）视为可用。
    private var isEnabled: Bool { option.action != nil || option.checked }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 12)
                .opacity(option.checked ? 1 : 0)
            Text(option.title ?? "")
                .font(.system(size: 12))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail = option.detail {
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .frame(width: panelWidth - 12, height: 24, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering && isEnabled ? Theme.Palette.hoverOverlay : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { guard isEnabled else { return }; action() }
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.micro, value: isHovering)
        .pointingHandOnHover(enabled: isEnabled)
    }
}
