//
//  SFTPToolView.swift
//  devkit
//
//  M6：SFTP 工具根视图 —— 左右两个远端目录面板 + 中间传输按钮列。
//  传输进行时底部悬浮进度条（当前文件 / 已完成项数 / 取消），错误短暂停留后自动消失。
//

import SwiftUI

struct SFTPToolView: View {
    let tool: SFTPTool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                SFTPSidePanelView(state: tool.side(.left))
                SFTPTransferColumn(tool: tool)
                SFTPSidePanelView(state: tool.side(.right))
            }
        }
        .padding(Theme.Metrics.terminalContentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let progress = tool.transfer {
                TransferHud(tool: tool, state: progress)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
            }
        }
    }
}

// MARK: - 中间传输按钮列

private struct SFTPTransferColumn: View {
    let tool: SFTPTool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            compactButton(symbol: "arrow.right",
                          hint: "把左侧选中项传到右侧当前目录",
                          enabled: tool.canTransferFromLeft) {
                tool.transfer(from: .left, to: .right)
            }
            compactButton(symbol: "arrow.left",
                          hint: "把右侧选中项传到左侧当前目录",
                          enabled: tool.canTransferFromRight) {
                tool.transfer(from: .right, to: .left)
            }
        }
        .frame(width: 34)
    }

    /// 紧凑图标按钮（体积约为旧版的 1/4）：背景与两侧文件面板一致（毛玻璃 + 随明暗的白/黑纱），
    /// 避免暗色下几乎看不见。可用时箭头用强调色，不可用时转灰。
    private func compactButton(symbol: String,
                               hint: String,
                               enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.5))
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(colorScheme == .dark
                          ? Color.black.opacity(0.22)
                          : Color.white.opacity(0.30))
            }
            .opacity(enabled ? 1 : 0.55)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(enabled ? Theme.Palette.accentStroke : Color.primary.opacity(0.10))
        )
        .disabled(!enabled)
        .help(hint)
    }
}

// MARK: - 传输进度悬浮条

private struct TransferHud: View {
    let tool: SFTPTool
    let state: SFTPTool.TransferState

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useAll]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(state.sourceLabel) → \(state.targetLabel)")
                            .font(.callout.weight(.semibold))
                        if !state.isEnumerating {
                            Text("\(state.completedFiles)/\(state.totalFiles) 个文件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = state.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    } else {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button(state.error == nil ? "取消" : "关闭") {
                    if state.error == nil { tool.cancelTransfer() } else { tool.dismissTransfer() }
                }
                .controlSize(.small)
            }
            // 整体进度条：平铺整宽（不占用右侧按钮那一列的空位）。
            if state.error == nil {
                progressBar
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(minWidth: 320)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.bannerCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.bannerCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: Theme.Palette.floatingShadow, radius: 6, y: 2)
    }

    /// 整体进度：已传字节 / 总字节；统计阶段显示提示。
    private var detail: String {
        if state.isEnumerating { return "正在递归统计文件…" }
        let name = state.currentItem.isEmpty ? "准备中…" : state.currentItem
        let done = Self.bytes.string(fromByteCount: Int64(state.bytesDone))
        let total = Self.bytes.string(fromByteCount: Int64(state.bytesTotal))
        return "\(name)　\(done) / \(total)"
    }

    @ViewBuilder
    private var progressBar: some View {
        if state.isEnumerating || state.bytesTotal == 0 {
            // 统计中，或总量全为 0（如空文件）：不确定态。
            ProgressView().progressViewStyle(.linear)
        } else {
            ProgressView(value: Double(state.bytesDone), total: Double(state.bytesTotal))
                .progressViewStyle(.linear)
        }
    }
}
