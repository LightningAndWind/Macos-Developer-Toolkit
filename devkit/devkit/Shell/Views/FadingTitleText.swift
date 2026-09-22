//
//  FadingTitleText.swift
//  devkit
//
//  单行标题文本：可用宽度不足时不画省略号，而是让超出的字形按视口右缘裁切，
//  并在最后 `titleFadeLength` 距离内渐隐消失——侧栏收窄时标题“只显示能展示的那部分”。
//  未溢出时右缘本就留白，遮罩不产生任何可见影响，因此无需额外测量是否截断。
//

import SwiftUI

struct FadingTitleText: View {
    let text: String
    var font: Font = Theme.Fonts.tabTitle

    var body: some View {
        GeometryReader { proxy in
            Text(text)
                .font(font)
                .lineLimit(1)
                // 以自然宽度排版（不截断、不加省略号），再按视口裁切，得到“硬切”的字形尾部。
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: max(1, proxy.size.width),
                       height: max(1, proxy.size.height),
                       alignment: .leading)
                .clipped()
                .mask(alignment: .trailing) { trailingFade }
        }
        // 固定行高：GeometryReader 纵向贪婪，不给高度会把整行撑满。
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Metrics.titleLineHeight)
    }

    /// 遮罩：前段完全不透明，尾部 `titleFadeLength` 内由不透明渐变到透明。
    private var trailingFade: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.black)
            LinearGradient(colors: [Color.black, Color.clear],
                           startPoint: .leading,
                           endPoint: .trailing)
                .frame(width: Theme.Metrics.titleFadeLength)
        }
    }
}
