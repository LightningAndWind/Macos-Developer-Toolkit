//
//  SSHJumpSupport.swift
//  devkit
//
//  跳板机（堡垒机）连接的共享支持：
//   - 记录侧：解析并校验 profile 的跳板引用（单跳；引用丢失/非法时降级直连）；
//   - 系统 ssh 引擎侧：把跳板组装成 `ProxyCommand=ssh -W %h:%p jumpuser@jumphost` 选项
//     （内层 ssh 独立携带跳板自己的私钥 / 端口 / known_hosts，与外层目标互不干扰）。
//  NIOSSH 密码引擎的隧道承载见 `SSHCarrierBuilder`。
//

import Foundation

/// 跳板相关的用户可读错误。
enum SSHJumpError: LocalizedError {
    /// 批处理引擎（SFTP / AI 执行的系统 ssh）无法交互输密码，跳板必须是私钥认证。
    case jumpPasswordUnsupported
    /// 跳板记录引用的私钥文件缺失。
    case jumpKeyMissing

    var errorDescription: String? {
        switch self {
        case .jumpPasswordUnsupported:
            return "该连接经由密码认证的跳板机；系统 ssh 批处理模式下无法交互输入跳板密码。请为跳板机改用私钥认证，或直接在 SSH 终端中连接。"
        case .jumpKeyMissing:
            return "跳板机记录的私钥文件缺失，请重新编辑该跳板机记录并选择私钥。"
        }
    }
}

@MainActor
enum SSHJumpSupport {

    /// 解析 profile 的跳板记录。以下情况一律返回 nil（按直连处理，容错历史数据）：
    /// 未配置跳板 / 引用的记录已被删 / 引用的是本地终端。
    static func resolveJump(for profile: SSHProfile) -> SSHProfile? {
        guard let jumpID = profile.jumpProfileID,
              let jump = SSHProfileStore.load(id: jumpID),
              jump.isRemote else { return nil }
        return jump
    }

    /// 系统 ssh 引擎的跳板参数（`-o` + `ProxyCommand=...` 两条 argv）。
    ///
    /// - `interactive == true`（SSH 终端）：跳板可用密码或私钥——内层 ssh 在终端 pty 里
    ///   交互提示密码 / 口令 / 首次主机指纹确认，与外层行为一致；
    /// - `interactive == false`（SFTP / AI 执行，BatchMode 非交互）：跳板必须是私钥认证，
    ///   否则抛 `SSHJumpError.jumpPasswordUnsupported`；同时给内层 ssh 配 accept-new +
    ///   应用私有 known_hosts（沿用各引擎已有的文件，跳板与目标写进同一个）。
    ///
    /// 不用 `-J`：ProxyJump 生成的内层 ssh 不继承命令行 `-i` 等选项，跳板与目标
    /// 用不同密钥 / 端口时无法表达；显式 ProxyCommand 才能对两跳分别下参。
    static func proxyJumpOptions(jump: SSHProfile,
                                 knownHostsPath: String?,
                                 interactive: Bool) throws -> [String] {
        if !interactive, jump.authKind != .key {
            throw SSHJumpError.jumpPasswordUnsupported
        }

        var inner: [String] = ["/usr/bin/ssh"]
        if jump.authKind == .key {
            guard let fileName = jump.privateKeyFileName,
                  let keyURL = SSHKeyStorage.resolvedURL(fileName: fileName) else {
                throw SSHJumpError.jumpKeyMissing
            }
            inner += ["-i", Self.quote(keyURL.path)]
        }
        if jump.port != SSHProfile.defaultPort {
            inner += ["-p", String(jump.port)]
        }
        if !interactive {
            inner += [
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "UserKnownHostsFile=\(Self.quote(knownHostsPath ?? "/dev/null"))",
                "-o", "ConnectTimeout=15",
            ]
        }
        // %h/%p 由外层 ssh 展开为目标主机/端口：隧道终点永远指向目标，而非跳板。
        inner += ["-W", "%h:%p", Self.quote("\(jump.username)@\(jump.host)")]

        return ["-o", "ProxyCommand=" + inner.joined(separator: " ")]
    }

    /// ProxyCommand 经 `/bin/sh -c` 执行，含空格路径需单引号保护。
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
