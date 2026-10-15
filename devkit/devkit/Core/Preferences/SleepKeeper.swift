//
//  SleepKeeper.swift
//  devkit
//
//  防锁屏保持器：持有 IOPMAssertion，阻止系统空闲时关闭屏幕 / 进入睡眠。
//  用于长时间任务（终端会话、构建、下载等）运行期间避免锁屏导致任务中断。
//
//  说明：
//  - 同时创建「阻止屏幕睡眠」与「阻止系统空闲睡眠」两条断言，
//    保证屏幕不熄灭、系统不因空闲而休眠锁屏。
//  - 断言随进程退出自动失效，应用退出无需显式清理。
//

import Foundation
import IOKit
import IOKit.pwr_mgt

/// 维持 IOPMAssertion 的防休眠开关。`start`/`stop` 均幂等。
@MainActor
final class SleepKeeper {
    static let shared = SleepKeeper()

    private var assertionIDs: [IOPMAssertionID] = []
    private(set) var isActive = false

    private init() {}

    /// 开始保持唤醒（屏幕常亮 + 阻止系统空闲睡眠）。
    func start() {
        guard !isActive else { return }
        let types = [
            kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionTypePreventUserIdleSystemSleep,
        ]
        var created: [IOPMAssertionID] = []
        for type in types {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "devkit 防止锁屏" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                created.append(id)
            }
        }
        // 全部创建失败才视为未生效，避免半开状态。
        guard !created.isEmpty else { return }
        assertionIDs = created
        isActive = true
    }

    /// 停止保持唤醒，恢复系统默认的锁屏/休眠策略。
    func stop() {
        guard isActive else { return }
        for id in assertionIDs {
            IOPMAssertionRelease(id)
        }
        assertionIDs = []
        isActive = false
    }
}
