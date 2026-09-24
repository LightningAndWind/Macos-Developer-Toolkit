//
//  ScrollIndicator.swift
//  devkit
//
//  自绘竖向滚动指示条（通用组件）：浅色胶囊轨道暗示可滚动范围，半透明细胶囊随滚动位置移动。
//  为什么不用原生滚动条：系统「始终显示滚动条」设置下，legacy 滚动条会带一条不透明的
//  白色轨道矩形，叠在毛玻璃卡片上非常突兀。列表类页面统一用本组件替代。
//

import SwiftUI
import AppKit

/// 滚动几何快照。
struct ScrollInfo: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var viewport: CGFloat = 0

    static let zero = ScrollInfo(offset: 0, content: 0, viewport: 0)

    var isOverflowing: Bool { content > viewport + 1 }
}

/// 指示条本体：贴靠 ScrollView 右缘（分割线一侧），不拦截鼠标事件。
struct ScrollIndicator: View {
    let info: ScrollInfo

    var body: some View {
        GeometryReader { geo in
            let trackHeight = geo.size.height
            let ratio = info.viewport > 0 ? min(1, trackHeight / max(info.content, 1)) : 1
            let knobHeight = max(28, trackHeight * ratio)
            let scrollable = max(1, info.content - info.viewport)
            let progress = min(1, max(0, info.offset / scrollable))
            let knobY = progress * (trackHeight - knobHeight)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Theme.Palette.scrollTrack)
                Capsule()
                    .fill(Theme.Palette.scrollKnob)
                    .frame(height: knobHeight)
                    .offset(y: knobY)
            }
        }
        .frame(width: Theme.Metrics.scrollIndicatorWidth)
        .padding(.vertical, Theme.Metrics.scrollIndicatorVPadding)
        .padding(.trailing, Theme.Metrics.scrollIndicatorTrailing)
        .allowsHitTesting(false)
    }
}

/// 监听滚动几何并叠加自绘指示条的通用修饰器，持有各自的 `ScrollInfo` 状态。
private struct ScrollIndicatorBarModifier: ViewModifier {
    @State private var info = ScrollInfo.zero

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollInfo.self) { geo in
                ScrollInfo(
                    offset: geo.contentOffset.y,
                    content: geo.contentSize.height,
                    viewport: geo.containerSize.height
                )
            } action: { _, new in
                info = new
            }
            .overlay(alignment: .trailing) {
                if info.isOverflowing {
                    ScrollIndicator(info: info)
                }
            }
    }
}

extension View {
    /// 为竖向 ScrollView 挂上与侧栏标签栏同款的自绘滚动指示条。
    /// 请配合 `.scrollIndicators(.never)` 使用：先彻底移除原生滚动条，再叠加本指示条。
    func scrollIndicatorBar() -> some View {
        modifier(ScrollIndicatorBarModifier())
    }
}

// MARK: - 终端（AppKit/SwiftTerm）同款悬浮滚动指示条

/// 终端滚动几何：由 `NSScroller` 的 doubleValue / knobProportion 映射而来。
@MainActor
@Observable
final class TerminalScrollModel {
    /// 0…1，视口在可滚动区间内的位置。
    var position: Double = 0
    /// 0…1，滑块占轨道的比例（=1 表示无需滚动）。
    var knob: Double = 1

    var show: Bool { knob < 0.995 }

    func update(position: Double, knob: Double) {
        self.position = position
        self.knob = knob
    }

    func reset() {
        position = 0
        knob = 1
    }
}

/// 终端悬浮指示条：与 `ScrollIndicator` 同款视觉（复用同一组 DesignToken），
/// 但数据来自终端 NSScroller（position/knob）而非 SwiftUI 滚动几何。
struct TerminalScrollIndicator: View {
    let position: Double
    let knob: Double

    var body: some View {
        GeometryReader { geo in
            let trackHeight = geo.size.height
            let knobHeight = max(24, trackHeight * min(max(knob, 0.05), 1))
            let knobY = min(max(position, 0), 1) * (trackHeight - knobHeight)
            ZStack(alignment: .top) {
                Capsule().fill(Theme.Palette.scrollTrack)
                Capsule()
                    .fill(Theme.Palette.scrollKnob)
                    .frame(height: knobHeight)
                    .offset(y: knobY)
            }
        }
        .frame(width: Theme.Metrics.scrollIndicatorWidth)
        .padding(.vertical, Theme.Metrics.scrollIndicatorVPadding)
        .padding(.trailing, Theme.Metrics.scrollIndicatorTrailing)
        .allowsHitTesting(false)
    }
}

/// 观察终端内部 `NSScroller`（SwiftTerm 驱动），把 doubleValue/knobProportion
/// 写进 `TerminalScrollModel`。scroller 被我们 `isHidden` 但值仍随滚动/输出更新，故可当数据源。
/// KVO 在主线程触发；向 @MainActor 模型写入时 hop 回主线程。
final class TerminalScrollerMonitor: NSObject, @unchecked Sendable {
    private weak var scroller: NSScroller?
    private let model: TerminalScrollModel
    private var observing = false

    init(scroller: NSScroller, model: TerminalScrollModel) {
        self.scroller = scroller
        self.model = model
    }

    /// 在主线程调用。
    func start() {
        guard !observing, let scroller else { return }
        observing = true
        scroller.addObserver(self, forKeyPath: #keyPath(NSScroller.doubleValue), options: [.new], context: nil)
        refresh()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        refresh()
    }

    private func refresh() {
        guard let scroller else { return }
        let position = scroller.doubleValue
        let knob = scroller.knobProportion
        let model = self.model
        Task { @MainActor in model.update(position: position, knob: knob) }
    }

    func stop() {
        guard observing, let scroller else { return }
        observing = false
        scroller.removeObserver(self, forKeyPath: #keyPath(NSScroller.doubleValue))
    }

    deinit {
        if observing, let scroller {
            scroller.removeObserver(self, forKeyPath: #keyPath(NSScroller.doubleValue))
        }
    }
}

extension View {
    /// 在终端区右侧叠加与 sftp 同款的悬浮滚动指示条；仅当终端有回滚溢出时显示。
    func terminalScrollIndicator(_ model: TerminalScrollModel) -> some View {
        overlay(alignment: .trailing) {
            if model.show {
                TerminalScrollIndicator(position: model.position, knob: model.knob)
            }
        }
    }
}
