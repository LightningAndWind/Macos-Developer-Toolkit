//
//  GitOutputConsoleView.swift
//  devkit
//
//  流式操作（clone / fetch / pull / push / merge / rebase）的实时输出控制台。
//  观察 tool.consoleLines 自动刷新；底部可复制全部 / 关闭。操作进行中保留进度指示。
//

import AppKit
import SwiftUI

struct GitOutputConsoleView: View {
    @Bindable var tool: GitTool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(tool.consoleTitle).font(.headline)
                if tool.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(tool.consoleLines.joined(separator: "\n"), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("复制全部输出")
                .buttonStyle(.borderless)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(tool.consoleLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.never)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
                .onChange(of: tool.consoleLines.count) { _, _ in
                    if let last = tool.consoleLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            HStack {
                Spacer()
                Button(tool.isBusy ? "进行中…" : "关闭") { tool.isConsolePresented = false }
                    .disabled(tool.isBusy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 620, height: 400)
    }
}
