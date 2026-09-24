//
//  SFTPSidePanelView.swift
//  devkit
//
//  M6：SFTP 单侧面板 —— 顶部连接区（未连接时选择 SSH 配置）、路径栏（上级 + 路径跳转）、
//  文件列表（单击选中、⌘-单击多选切换、双击目录进入）、底部条目数与错误信息。
//

import SwiftUI
import AppKit

struct SFTPSidePanelView: View {
    @Bindable var state: SFTPSideState
    @Environment(\.colorScheme) private var colorScheme

    @State private var pathDraft = ""
    @State private var showPicker = false
    @State private var newFolderName = ""
    @State private var isNamingFolder = false
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            pathBar
            fileList
            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // 毛玻璃：底层材质提供模糊，上覆一层颜色提高不透明度。
            // 浅色模式用白纱，深色模式换成暗色（避免深色下白纱把面板提得过亮）。
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(colorScheme == .dark
                          ? Color.black.opacity(0.22)
                          : Color.white.opacity(0.30))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.6))
        )
        .onAppear { pathDraft = state.path }
        .onChange(of: state.path) { _, newValue in pathDraft = newValue }
        .sheet(isPresented: $showPicker) {
            SFTPProfilePicker(side: state)
        }
        .alert("确认删除", isPresented: $isConfirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await state.deleteSelection() }
            }
        } message: {
            Text("确定删除选中的 \(state.selection.count) 项？文件夹会连同其内容一并删除，无法撤销。")
        }
        .alert("新建文件夹", isPresented: $isNamingFolder) {
            TextField("名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                Task {
                    await state.createFolder(named: newFolderName)
                    newFolderName = ""
                }
            }
        }
    }

    // MARK: 头部

    @ViewBuilder
    private var header: some View {
        switch state.state {
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在连接 \(state.profile.map { "\($0.username)@\($0.host)" } ?? "本机")…")
                    .foregroundStyle(.secondary)
            }
        case .connected:
            HStack(spacing: 8) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(state.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                iconButton("arrow.clockwise", "刷新") {
                    Task { await state.refresh() }
                }
                iconButton("folder.badge.plus", "新建文件夹") {
                    isNamingFolder = true
                }
                iconButton("trash", "删除选中项", disabled: state.selection.isEmpty) {
                    isConfirmingDelete = true
                }
                iconButton("xmark.circle", "断开连接") {
                    state.disconnect()
                }
            }
        default:
            VStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(state.side == .left ? "左侧未连接" : "右侧未连接")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("选择 SSH 连接…") { showPicker = true }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    Button("连接本地") {
                        Task { await state.connectLocal() }
                    }
                    .controlSize(.small)
                }
                if let failure = state.connectionFailure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 路径栏

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await state.goUp() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(!state.isConnected || state.path == "/")
            .help("上级目录")

            TextField("路径", text: $pathDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .disabled(!state.isConnected)
                .onSubmit {
                    Task { await state.navigate(to: pathDraft) }
                }

            if state.isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: 文件列表

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(state.sortedEntries) { entry in
                    SFTPFileRow(
                        entry: entry,
                        isSelected: state.selection.contains(entry.name),
                        onSelect: { additive in state.applySelection(name: entry.name, additive: additive) },
                        onOpen: { Task { await state.enter(entry) } }
                    )
                }
            }
            .padding(.vertical, 2)
            // 右侧留一点余量：避免行尾的时间/大小与滚动条重叠。
            .padding(.trailing, 8)
        }
        // 原生滚动条在系统「始终显示滚动条」下会带一条不透明的白色轨道矩形，非常突兀，
        // 故彻底移除后叠加与侧栏标签栏同款的自绘滚动指示条（Core/DesignSystem/ScrollIndicator.swift）。
        .scrollIndicators(.never)
        .scrollIndicatorBar()
        .overlay {
            if state.isConnected && state.sortedEntries.isEmpty && !state.isLoading {
                Text("空目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!state.isConnected)
    }

    // MARK: 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(state.entries.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !state.selection.isEmpty {
                    Text("已选 \(state.selection.count) 项")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            if let error = state.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private func iconButton(_ symbol: String, _ tip: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(disabled)
        .help(tip)
    }
}

// MARK: - 文件行

/// 自定义命中：单 tap 选中（立即响应）、⌘-tap 多选切换、双击进入目录。
/// 不用 `List(selection:)` 也不用 `onTapGesture(count: 2)`：前者会与行手势抢鼠标
/// （表现为“偶尔才能选中”），后者会拖慢单击。改用 count:1 + 手动时间差判双击。
private struct SFTPFileRow: View {
    let entry: SFTPEntry
    let isSelected: Bool
    let onSelect: (_ additive: Bool) -> Void
    let onOpen: () -> Void

    @State private var isHovering = false
    @State private var lastTapDate: Date?

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useAll]
        f.countStyle = .file
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// 双击阈值：跟随系统「通用 → 双击速度」偏好。
    private static var doubleTapInterval: TimeInterval {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        if let raw = global?["AppleDoubleClickInterval"] as? NSNumber, raw.doubleValue > 0 {
            return raw.doubleValue
        }
        return 0.5
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let mtime = entry.attrs.mtime {
                Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(mtime))))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !entry.isDirectory, let size = entry.attrs.size {
                Text(Self.byteFormatter.string(fromByteCount: Int64(size)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16)
                                 : (isHovering ? Theme.Palette.hoverOverlay : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isSelected ? Theme.Palette.accentStroke : Color.clear, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .onTapGesture { handleTap() }
    }

    private func handleTap() {
        let now = Date()
        let additive = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if let last = lastTapDate, now.timeIntervalSince(last) < Self.doubleTapInterval {
            lastTapDate = nil
            if entry.isDirectory {
                onSelect(false)
                onOpen()
            } else {
                onSelect(additive)
            }
        } else {
            lastTapDate = now
            onSelect(additive)
        }
    }
}
