//
//  LauncherView.swift
//  devkit
//
//  新标签入口：工具卡片 + 搜索。
//

import SwiftUI

struct LauncherView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""

    private var filteredDescriptors: [ToolDescriptor] {
        let all = ToolRegistry.shared.descriptors
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        let q = query.lowercased()
        return all.filter {
            $0.title.lowercased().contains(q)
            || $0.subtitle.lowercased().contains(q)
            || $0.category.rawValue.lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if query.isEmpty {
                    ForEach(ToolDescriptor.ToolCategory.allCases, id: \.self) { cat in
                        let items = filteredDescriptors.filter { $0.category == cat }
                        if !items.isEmpty {
                            section(title: cat.rawValue) {
                                grid(items)
                            }
                        }
                    }
                } else {
                    section(title: "搜索结果") {
                        grid(filteredDescriptors)
                    }
                }
                Spacer(minLength: 40)
            }
            .padding(32)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "swissarmyknife")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("新建标签")
                .font(.title.weight(.semibold))
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索工具…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .frame(maxWidth: 420)
            .autocorrectionDisabled()
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(_ items: [ToolDescriptor]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
            spacing: 12
        ) {
            ForEach(items) { d in
                ToolCard(descriptor: d, compact: false) { open(d) }
            }
        }
    }

    private func open(_ descriptor: ToolDescriptor) {
        RecentToolsStore.shared.record(descriptor.id)
        // HTTP / SSH：先建空白标签，再弹“新建 / 打开已保存”选择框（HTTP M5、SSH M4）。
        if descriptor.id == HTTPTool.descriptor.id {
            if let tab = appState.tabManager.openTool(descriptor: descriptor) {
                appState.httpChooserTabID = tab.id
                appState.saveSession()
            }
        } else if descriptor.id == SSHTool.descriptor.id {
            if let tab = appState.tabManager.openTool(descriptor: descriptor) {
                appState.sshChooserTabID = tab.id
                appState.saveSession()
            }
        } else if descriptor.id == GitTool.descriptor.id {
            if let tab = appState.tabManager.openTool(descriptor: descriptor) {
                appState.gitChooserTabID = tab.id
                appState.saveSession()
            }
        } else {
            appState.openTool(descriptor)
        }
    }
}

// MARK: - Tool card

private struct ToolCard: View {
    let descriptor: ToolDescriptor
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: descriptor.symbolName)
                    .font(.system(size: compact ? 20 : 26, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(descriptor.title)
                        .font(.system(size: compact ? 13 : 15, weight: .semibold))
                        .lineLimit(1)
                    if !compact {
                        Text(descriptor.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(compact ? 10 : 14)
            .frame(width: compact ? 220 : nil, alignment: .leading)
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("\(descriptor.title) - \(descriptor.subtitle)")
    }
}

// MARK: - Recent store

@MainActor
final class RecentToolsStore {
    static let shared = RecentToolsStore()
    private let key = "devkit.recentTools"
    private let maxCount = 6
    private let defaults = UserDefaults.standard

    func record(_ toolID: String) {
        var dict = (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:]
        dict[toolID] = Date.now.timeIntervalSince1970
        defaults.set(dict, forKey: key)
    }

    func recentDescriptors() -> [ToolDescriptor] {
        let dict = (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let sorted = dict.sorted { $0.value > $1.value }.prefix(maxCount)
        let registry = ToolRegistry.shared
        return sorted.compactMap { registry.descriptor(for: $0.key) }
    }
}

#Preview {
    LauncherView().environment(AppState.shared)
        .frame(width: 800, height: 600)
}
