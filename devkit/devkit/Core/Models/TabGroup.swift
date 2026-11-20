//
//  TabGroup.swift
//  devkit
//
//  Chrome 式标签分组：名称 + 颜色 + 是否折叠。
//

import SwiftUI

/// 标签分组。成员通过 `Tab.groupID` 反向关联，避免双向引用同步问题。
@Observable
final class TabGroup: Identifiable, Hashable {
    let id: UUID
    var name: String
    var color: GroupColor
    var isCollapsed: Bool

    init(id: UUID = UUID(),
         name: String,
         color: GroupColor,
         isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
    }

    static func == (lhs: TabGroup, rhs: TabGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// 分组颜色：预置一组 macOS 风格色，避免用户直接选 Color。
    enum GroupColor: String, CaseIterable, Codable, Hashable {
        case gray, blue, purple, pink, red, orange, yellow, green, teal

        var swiftUIColor: Color {
            // 简约模式：九种预置色映射为不同浓度的 primary（黑/白随明暗自适应，
            // 整体黑白灰化的同时保留分组间的明度区分度）。
            if Theme.minimalMode {
                return Color.primary.opacity(minimalOpacity)
            }
            switch self {
            case .gray:   return .gray
            case .blue:   return .blue
            case .purple: return .purple
            case .pink:   return .pink
            case .red:    return .red
            case .orange: return .orange
            case .yellow: return .yellow
            case .green:  return .green
            case .teal:   return .teal
            }
        }

        /// 简约模式下的 primary 浓度（0-1）：各预置色拉开深浅差，分组色带仍可辨认。
        private var minimalOpacity: Double {
            switch self {
            case .gray:   return 0.55
            case .blue:   return 0.45
            case .purple: return 0.40
            case .pink:   return 0.62
            case .red:    return 0.35
            case .orange: return 0.58
            case .yellow: return 0.68
            case .green:  return 0.50
            case .teal:   return 0.42
            }
        }
    }
}
