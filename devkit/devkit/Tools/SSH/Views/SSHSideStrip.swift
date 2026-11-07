//
//  SSHSideStrip.swift
//  devkit
//
//  SSH 工具右缘竖向工具条（类 IDE 的右 stripe）：窄条卡片自顶向下排列图标按钮。
//  为何独立于横幅 / 悬浮钮：横幅内的图标钮触控目标过小不易点中，且本地会话没有横幅；
//  竖条三种会话状态（本地 / 远程 / 未选择）常驻同一位置，触控目标 28×28 且悬停高亮。
//  后续新增侧边功能（历史、传输列表等）往 items 里加一项即可。
//

import SwiftUI

/// 工具条按钮项。
struct SSHSideStripItem: Identifiable {
    let id: String
    let symbol: String
    let help: String
    var isActive: Bool = false
    let action: () -> Void
}

struct SSHSideStripView: View {
    let items: [SSHSideStripItem]
    @State private var hoveringID: String?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(items) { item in
                button(for: item)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .frame(width: Theme.Metrics.sideStripWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .terminalCardSurface()
    }

    /// 单个按钮：28×28 触控目标，激活态 accent 着色 + 描边，悬停浅色高亮。
    private func button(for item: SSHSideStripItem) -> some View {
        Button {
            item.action()
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: Theme.Metrics.sideStripButtonSize,
                       height: Theme.Metrics.sideStripButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(item.isActive ? Color.accentColor.opacity(0.16)
                              : (hoveringID == item.id ? Theme.Palette.hoverOverlay : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(item.isActive ? Theme.Palette.accentStroke : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(item.isActive ? Color.accentColor : Color.secondary)
        .onHover { hoveringID = $0 ? item.id : (hoveringID == item.id ? nil : hoveringID) }
        .help(item.help)
        .animation(Theme.Motion.micro, value: hoveringID)
    }
}
