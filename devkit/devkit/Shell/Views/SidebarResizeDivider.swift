//
//  SidebarResizeDivider.swift
//  devkit
//
//  可拖拽的列宽分割线（现用于 Git 变更列表的「列表 / 差异预览」分栏）：视觉上是 1pt
//  细线，热区加宽到 `splitterHitWidth`（向两侧溢出，不占据布局宽度）。悬停显示左右
//  拖拽光标并高亮，按住横向拖动实时改变列宽（限幅在 min/max 之间），双击恢复默认宽度。
//  左侧标签栏已改为固定四档宽度，不再使用本组件（见 AppShellView / TabBarView）。
//
//  ## 性能约定
//  - `ColumnSizing` 是独立的 @Observable 对象：拖拽每帧只写它的 `liveWidth`，
//    只有真正读 `currentWidth` 的列视图需要失效；宿主视图（可能挂着很重的常驻
//    工具标签、sheet、毛玻璃背景）完全不参与逐帧重算。
//  - 拖拽期间绝不写 UserDefaults，落定（onCommit）时由宿主一次性持久化。
//  - 本视图 body **不读取** sizing 的任何属性，因此连分割线自身都不会逐帧重算 body。
//

import AppKit
import SwiftUI

/// 列宽的拖拽状态与持久化配置。
///
/// 拆成 @Observable 对象而非宿主视图的 @State 值，是为了让「写宽度」和「读宽度」
/// 落在不同视图上：写方（分割线手势）与读方（列视图）各自失效，宿主不参与。
@MainActor
@Observable
final class ColumnSizing {
    /// UserDefaults 键（构造时读初值；写入由宿主的 @AppStorage 负责）。
    let defaultsKey: String
    let defaultWidth: CGFloat
    let range: ClosedRange<CGFloat>

    /// 已落定的宽度（与 UserDefaults 中的值一致）。
    var baseWidth: CGFloat
    /// 拖拽中的瞬时宽度；nil 表示未在拖拽。
    var liveWidth: CGFloat?
    /// 当前生效宽度。
    var currentWidth: CGFloat { liveWidth ?? baseWidth }

    init(defaultsKey: String, defaultWidth: CGFloat, range: ClosedRange<CGFloat>) {
        self.defaultsKey = defaultsKey
        self.defaultWidth = defaultWidth
        self.range = range
        // @AppStorage 在 @State 初始值求值阶段尚未注入，直接读同一个键（含限幅容错）。
        let raw = (UserDefaults.standard.object(forKey: defaultsKey) as? Double) ?? Double(defaultWidth)
        self.baseWidth = Self.clamp(CGFloat(raw), in: range)
    }

    func clamped(_ width: CGFloat) -> CGFloat { Self.clamp(width, in: range) }

    /// 拖拽落定 / 双击恢复：退出拖拽态，返回最终宽度供宿主一次性写 UserDefaults。
    @discardableResult
    func settle() -> CGFloat {
        let final = clamped(liveWidth ?? currentWidth)
        liveWidth = nil
        baseWidth = final
        return final
    }

    private static func clamp(_ width: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(width, range.lowerBound), range.upperBound)
    }
}

struct SidebarResizeDivider: View {
    /// 宽度的写入通道（读取由对应列视图负责；两者共享同一对象）。
    let sizing: ColumnSizing
    /// 一次调整落定（拖拽结束 / 双击恢复）后的回调：宿主在此把最终宽度持久化，
    /// 避免拖拽期间每帧写 UserDefaults（同步 I/O 会明显拖累跟手度）。
    var onCommit: (() -> Void)? = nil

    /// 悬停中（决定光标与高亮）。
    @State private var isHovering = false
    /// 拖拽起始宽度；nil 表示当前没有拖拽。手势内部状态，不参与宽度广播。
    @State private var startWidth: CGFloat?

    private var isDragging: Bool { startWidth != nil }

    var body: some View {
        Rectangle()
            .fill(isHovering || isDragging ? Theme.Palette.splitterActive : Theme.Palette.splitter)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            // 热区居中覆盖在细线两侧：overlay 溢出自身边界参与命中测试，
            // 因此不会像 frame(width:) 那样在布局里占掉 7pt，两列仍紧贴分割线。
            .overlay {
                Color.clear
                    .frame(width: Theme.Metrics.splitterHitWidth)
                    .contentShape(Rectangle())
                    .gesture(resizeGesture)
                    .onTapGesture(count: 2) {
                        sizing.liveWidth = nil
                        sizing.baseWidth = sizing.defaultWidth
                        onCommit?()
                    }
            }
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .animation(Theme.Motion.micro, value: isHovering)
            .animation(Theme.Motion.micro, value: isDragging)
            .help("拖动调整宽度，双击恢复默认")
    }

    /// 横向拖拽：以按下时的宽度为基准累加位移，限幅到 [min, max]。
    /// `minimumDistance: 1` 让单击（双击恢复）不被拖拽手势吞掉。
    /// 坐标空间必须用 `.global`：分割线自身会随宽度移动，用 `.local` 时位移会被视图位移抵消，
    /// 解出 `w = w0 + 指针位移 / 2`，表现为“分割线只跟上一半”的迟滞手感。
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if startWidth == nil { startWidth = sizing.currentWidth }
                let base = startWidth ?? sizing.currentWidth
                sizing.liveWidth = sizing.clamped(base + value.translation.width)
            }
            .onEnded { _ in
                startWidth = nil
                onCommit?()
            }
    }
}
