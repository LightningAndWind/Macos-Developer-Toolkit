//
//  ToolSkeletonViews.swift
//  devkit
//
//  M1 阶段的空工具占位视图；M2/M3/M4 会替换为真实实现。
//

import SwiftUI

/// 通用占位视图：显示工具图标 + 里程碑提示。
struct ToolPlaceholderView: View {
    let descriptor: ToolDescriptor
    let milestone: String
    let bullets: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: descriptor.symbolName)
                        .font(.system(size: 32))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.title).font(.title.weight(.semibold))
                        Text(descriptor.subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(milestone)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(.tint)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("规划能力").font(.headline)
                    ForEach(bullets, id: \.self) { b in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.secondary)
                            Text(b).font(.callout)
                        }
                    }
                }
                Text("当前为骨架实现，具体功能将在后续里程碑落地。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.ultraThinMaterial)
    }
}
