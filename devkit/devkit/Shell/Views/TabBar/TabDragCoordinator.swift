//
//  TabDragCoordinator.swift
//  devkit
//
//  Chrome 风格的标签拖拽排序协调器：
//  - 被拖标签以浮动预览的形式直接跟随指针移动；
//  - 其他标签根据当前落点实时“避让”让出空位；
//  - 落点可以是分组头 / 组内标签 / 未分组标签，松手即完成重排与分组归属变更。
//
//  拖拽过程中不修改数据模型（TabManager），仅在松手时一次性提交，
//  以保证坐标快照稳定、动画可控。
//

import SwiftUI

/// 拖拽手势与浮动预览共用的命名坐标空间（以 ScrollView 左上角为原点）。
enum TabDragSpace {
    static let name = "sidebar"
}

/// 松手时的落点解析结果。
struct TabDropResult {
    /// 被拖拽的标签。
    let draggedID: UUID
    /// 落点参照的标签（落在分组头时为 nil）。
    let targetTabID: UUID?
    /// 落点所属分组（落在未分组区域时为 nil）。
    let targetGroupID: UUID?
}

/// 拖拽协调器：持有本次拖拽的瞬时状态，供 `TabBarView` 及其子行共享。
@MainActor
@Observable
final class TabDragCoordinator {
    /// 正在被拖拽的标签 ID；nil 表示当前没有拖拽。
    var draggedID: UUID?
    /// 浮动预览左上角的 Y（侧栏坐标空间）。
    var previewTopY: CGFloat = 0
    /// 浮动预览相对中心的水平偏移（已限幅，营造轻微“跟手”位移）。
    var previewShiftX: CGFloat = 0
    /// 当前落点在 layoutRows 中的索引。
    private(set) var hoverIndex: Int = 0

    /// 拖拽开始时的行顺序快照（layoutRows 的 id）。
    private var rowOrder: [UUID] = []
    /// 拖拽开始时各行在侧栏坐标空间中的基础帧（不含避让偏移）。
    private var rowFrames: [UUID: CGRect] = [:]
    /// 抓取点相对被拖行左上角的偏移，保证预览“贴手”。
    private var grabOffset: CGPoint = .zero
    /// 拖拽起始时指针的 X，用于计算水平跟手位移。
    private var startPointerX: CGFloat = 0
    /// 行高 + 行距，用于把指针位置换算成落点索引。
    private var stride: CGFloat = 1

    /// 开始拖拽：冻结当前布局快照，记录抓取点。
    func beginDrag(tabID: UUID,
                   rows: [TabManager.Row],
                   frames: [UUID: CGRect],
                   location: CGPoint) {
        guard let frame = frames[tabID] else { return }
        let order = rows.map(\.id)

        self.rowOrder = order
        self.rowFrames = frames
        self.stride = Theme.Metrics.tabRowHeight + Theme.Metrics.tabGap
        self.grabOffset = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        self.startPointerX = location.x
        self.previewTopY = frame.minY
        self.previewShiftX = 0
        self.draggedID = tabID
        self.hoverIndex = order.firstIndex(of: tabID) ?? 0
    }

    /// 拖拽进行中：更新浮动预览位置与落点索引。
    func updateDrag(location: CGPoint) {
        guard draggedID != nil else { return }
        previewTopY = location.y - grabOffset.y
        let maxShift = Theme.Metrics.dragMaxHorizontalShift
        previewShiftX = min(max(location.x - startPointerX, -maxShift), maxShift)

        let centerY = previewTopY + Theme.Metrics.tabRowHeight / 2
        let relative = centerY - rowTop(0)
        let raw = Int((relative / stride).rounded())
        let clamped = min(max(raw, 0), max(0, rowOrder.count - 1))
        // 仅在落点真正跨越行边界时才更新，避免每次鼠标移动都触发整个列表重绘。
        if clamped != hoverIndex { hoverIndex = clamped }
    }

    /// 某行在本次拖拽中应施加的避让偏移。
    func avoidanceOffset(for rowID: UUID) -> CGFloat {
        guard let draggedID,
              let from = rowOrder.firstIndex(of: draggedID),
              let i = rowOrder.firstIndex(of: rowID),
              i != from else { return 0 }
        let to = hoverIndex
        if from < to, i > from, i <= to { return -stride }
        if from > to, i >= to, i < from { return stride }
        return 0
    }

    /// 结束拖拽：解析落点，返回提交所需信息；随后清空瞬时状态。
    func endDrag(rows: [TabManager.Row]) -> TabDropResult? {
        guard let draggedID else { return nil }
        var targetTabID: UUID?
        var targetGroupID: UUID?
        if hoverIndex >= 0, hoverIndex < rowOrder.count {
            let targetID = rowOrder[hoverIndex]
            if let row = rows.first(where: { $0.id == targetID }) {
                switch row.kind {
                case .groupHeader(let g):
                    targetGroupID = g.id
                case .tab(let t):
                    targetTabID = t.id
                    targetGroupID = t.groupID
                }
            }
        }
        reset()
        return TabDropResult(draggedID: draggedID, targetTabID: targetTabID, targetGroupID: targetGroupID)
    }

    // MARK: - Private

    private func rowTop(_ index: Int) -> CGFloat {
        guard index >= 0, index < rowOrder.count,
              let top = rowFrames[rowOrder[index]]?.minY else {
            return rowFrames.values.map(\.minY).min() ?? 0
        }
        return top
    }

    private func reset() {
        draggedID = nil
        rowOrder = []
        rowFrames = [:]
        grabOffset = .zero
        startPointerX = 0
        hoverIndex = 0
        previewTopY = 0
        previewShiftX = 0
    }
}

// MARK: - Row frame reporting

/// 各行在侧栏坐标空间中的帧汇总（拖拽未开始时用于建立布局快照）。
struct TabRowFrames: Equatable {
    var frames: [UUID: CGRect] = [:]
}

struct TabRowFramesKey: PreferenceKey {
    static var defaultValue: TabRowFrames { TabRowFrames() }
    static func reduce(value: inout TabRowFrames, nextValue: () -> TabRowFrames) {
        value.frames.merge(nextValue().frames) { _, new in new }
    }
}

// MARK: - Floating preview

/// 跟随指针的浮动拖拽预览：图标 + 标题胶囊，带轻微放大与投影，营造“拿起”的层次。
struct TabDragPreviewView: View {
    let tab: Tab
    /// 所属分组颜色（由上层从 TabManager 解析后传入，避免预览层反向依赖）。
    var groupColor: Color?

    private var symbolName: String {
        ToolRegistry.shared.descriptor(for: tab.toolID)?.symbolName ?? "questionmark.app"
    }

    var body: some View {
        HStack(spacing: Theme.Metrics.tabInnerSpacing) {
            if let groupColor {
                RoundedRectangle(cornerRadius: 2)
                    .fill(groupColor)
                    .frame(width: Theme.Metrics.groupAccentWidth)
            }
            Image(systemName: symbolName)
                .font(Theme.Fonts.tabSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(tab.displayTitle)
                .font(Theme.Fonts.tabTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Metrics.tabHPadding)
        .frame(height: Theme.Metrics.tabRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.tabCornerRadius)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.tabCornerRadius)
                .strokeBorder(Theme.Palette.accentStroke, lineWidth: 1)
        )
        .shadow(color: Theme.Palette.dragShadow, radius: 6, x: 0, y: 3)
    }
}
