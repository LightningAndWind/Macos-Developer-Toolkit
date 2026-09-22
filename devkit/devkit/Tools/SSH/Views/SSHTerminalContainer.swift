//
//  SSHTerminalContainer.swift
//  devkit
//
//  M4：把 SwiftTerm 的 TerminalView 桥接到 SSHClient（远程会话）。
//  远端输出（client.incoming）feed 进终端；本地键入经 delegate.send 下发；尺寸变化经 resize 上报。
//  工程默认 MainActor 隔离，而 SwiftTerm 在主线程回调 delegate，故 delegate 方法标 nonisolated
//  并用 MainActor.assumeIsolated 安全切回主 actor。
//

import AppKit
import SwiftUI
import SwiftTerm

/// 远程 SSH 终端容器。
struct SSHTerminalContainer: NSViewRepresentable {
    let client: SSHClient
    /// 首次可用尺寸回报（用于以合理初始尺寸连接）。
    var onSize: ((Int, Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(client: client) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: NSFont(name: "Menlo", size: 12))
        view.terminalDelegate = context.coordinator
        view.translatesAutoresizingMaskIntoConstraints = true
        TerminalTheme.apply(to: view)
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.client = client
        // 消费远端输出（仅启动一次）。
        context.coordinator.startConsumingIfNeeded()
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.stopConsuming()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        var client: SSHClient
        private weak var view: TerminalView?
        private var consumeTask: Task<Void, Never>?
        private var started = false

        init(client: SSHClient) { self.client = client }

        func attach(_ view: TerminalView) { self.view = view }

        /// 启动一个 Task 把 client.incoming 持续 feed 到终端（主线程）。
        func startConsumingIfNeeded() {
            guard !started else { return }
            started = true
            consumeTask = Task { [weak self, weak view] in
                guard let stream = self?.client.incoming else { return }
                for await bytes in stream {
                    if Task.isCancelled { break }
                    guard let view else { continue }
                    view.feed(byteArray: ArraySlice(bytes))
                }
            }
        }

        func stopConsuming() {
            consumeTask?.cancel()
            consumeTask = nil
        }

        // MARK: TerminalViewDelegate（SwiftTerm 于主线程回调）

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            MainActor.assumeIsolated { self.client.write(bytes) }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { self.client.resize(cols: newCols, rows: newRows) }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            MainActor.assumeIsolated {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(content, forType: .string)
            }
        }
    }
}
