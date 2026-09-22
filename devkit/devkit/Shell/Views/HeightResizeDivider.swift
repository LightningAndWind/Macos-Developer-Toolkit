//
//  HeightResizeDivider.swift
//  devkit
//
//  上下两分区之间的可拖拽横向分割线：视觉为 1pt 细线，热区加高到 `splitterHitHeight`
//  （向上下溢出，不占据布局高度）。悬停显示上下拖拽光标并高亮，按住纵向拖动实时改变
//  上区高度（限幅在 min/max 之间），双击恢复默认（上下各半）。与 SidebarResizeDivider 对称。
//

import AppKit
import SwiftUI

struct HeightResizeDivider: View {
    /// 上区高度绑定（由上层根据容器高度换算，拖动过程即时生效）。
    @Binding var height: CGFloat
    /// 可调范围。
    let range: ClosedRange<CGFloat>
    /// 双击恢复的默认高度。
    let defaultHeight: CGFloat

    /// 悬停中（决定光标与高亮）。
    @State private var isHovering = false
    /// 拖拽起始高度；nil 表示当前没有拖拽。
    @State private var startHeight: CGFloat?

    private var isDragging: Bool { startHeight != nil }

    var body: some View {
        Rectangle()
            .fill(isHovering || isDragging ? Theme.Palette.splitterActive : Theme.Palette.splitter)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            // 热区居中覆盖在细线上下：overlay 溢出自身边界参与命中测试，
            // 因此不会像 frame(height:) 那样在布局里占掉额外高度，上下两区仍紧贴分割线。
            .overlay {
                Color.clear
                    .frame(height: Theme.Metrics.splitterHitHeight)
                    .contentShape(Rectangle())
                    .gesture(resizeGesture)
                    .onTapGesture(count: 2) { height = defaultHeight }
            }
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .animation(Theme.Motion.micro, value: isHovering)
            .animation(Theme.Motion.micro, value: isDragging)
            .help("拖动调整请求区与响应区的高度，双击恢复默认")
    }

    /// 纵向拖拽：以按下时的高度为基准累加位移，限幅到 [min, max]。
    /// 向下拖动（translation.height 为正）增大上区高度。
    /// 坐标空间用 `.global`：分割线自身会随高度移动，`.local` 会让位移被视图位移抵消而迟滞。
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if startHeight == nil { startHeight = height }
                let base = startHeight ?? height
                height = min(max(base + value.translation.height, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in startHeight = nil }
    }
}
