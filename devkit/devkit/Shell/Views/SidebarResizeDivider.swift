//
//  SidebarResizeDivider.swift
//  devkit
//
//  侧栏与内容区之间的可拖拽分割线：视觉上是 1pt 细线，热区加宽到 `splitterHitWidth`
//  （向两侧溢出，不占据布局宽度）。悬停显示左右拖拽光标并高亮，按住横向拖动实时改变
//  侧栏宽度（限幅在 min/max 之间），双击恢复默认宽度。
//

import AppKit
import SwiftUI

struct SidebarResizeDivider: View {
    /// 侧栏宽度绑定（由上层 `@AppStorage` 提供，拖动过程即时生效并自动持久化）。
    @Binding var width: CGFloat
    /// 可调范围。
    let range: ClosedRange<CGFloat>
    /// 双击恢复的默认宽度。
    let defaultWidth: CGFloat

    /// 悬停中（决定光标与高亮）。
    @State private var isHovering = false
    /// 拖拽起始宽度；nil 表示当前没有拖拽。
    @State private var startWidth: CGFloat?

    private var isDragging: Bool { startWidth != nil }

    var body: some View {
        Rectangle()
            .fill(isHovering || isDragging ? Theme.Palette.splitterActive : Theme.Palette.splitter)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            // 热区居中覆盖在细线两侧：overlay 溢出自身边界参与命中测试，
            // 因此不会像 frame(width:) 那样在布局里占掉 7pt，侧栏与内容区仍紧贴分割线。
            .overlay {
                Color.clear
                    .frame(width: Theme.Metrics.splitterHitWidth)
                    .contentShape(Rectangle())
                    .gesture(resizeGesture)
                    .onTapGesture(count: 2) { width = defaultWidth }
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
            .help("拖动调整侧栏宽度，双击恢复默认")
    }

    /// 横向拖拽：以按下时的宽度为基准累加位移，限幅到 [min, max]。
    /// `minimumDistance: 1` 让单击（双击恢复）不被拖拽手势吞掉。
    /// 坐标空间必须用 `.global`：分割线自身会随宽度移动，用 `.local` 时位移会被视图位移抵消，
    /// 解出 `w = w0 + 指针位移 / 2`，表现为“分割线只跟上一半”的迟滞手感。
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if startWidth == nil { startWidth = width }
                let base = startWidth ?? width
                width = min(max(base + value.translation.width, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in startWidth = nil }
    }
}
