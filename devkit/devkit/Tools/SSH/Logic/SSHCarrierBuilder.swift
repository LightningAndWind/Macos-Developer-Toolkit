//
//  SSHCarrierBuilder.swift
//  devkit
//
//  NIOSSH 密码引擎的「承载通道」工厂：为三个密码引擎（终端 SSHClient / SFTP / AI 执行）
//  统一建立 pipeline 中持有目标 NIOSSHHandler 的通道，避免隧道逻辑三处复制后漂移。
//
//   - 直连：TCP socket 上直接挂目标 NIOSSHHandler（原有路径原样下沉到这里）；
//   - 经跳板：TCP 连跳板并完成 NIOSSH 认证 → 在跳板连接上开 direct-tcpip 子通道
//     （SSH 语义 = 让跳板替我们去连目标主机）→ 在该子通道的 pipeline 里再叠加一个
//     目标主机的 NIOSSHHandler，目标握手字节经跳板隧道透传（SSH-over-SSH）。
//     会话 / sftp / exec 子通道一律从目标 handler 创建，下游各引擎零改动。
//
//  认证委托由调用方在主 actor 构造后传入（凭据不落 nonisolated 上下文，约定同 SSHSessionRegistry）。
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// 承载通道工厂（nonisolated：在 NIO 事件循环 / 后台任务中使用）。
nonisolated enum SSHCarrierBuilder {

    /// 建立结果。
    ///
    /// `rootChannel` 与 `carrierChannel` 直连时是同一个通道；经跳板时分别是
    /// 「跳板 TCP 连接」与「承载目标 SSH 的 direct-tcpip 子通道」——**断开时两者都要关**
    /// （只关子通道会留下一条无人的跳板 TCP 连接）。
    struct Established: @unchecked Sendable {
        let rootChannel: Channel
        let carrierChannel: Channel
    }

    /// 建立承载通道。`jumpProfile == nil` 走直连；否则经跳板隧道。
    /// `connectTimeout`：TCP 连接（跳板或目标）的超时；nil 用 NIO 默认（10s）。
    static func establish(profile: SSHProfile,
                          jumpProfile: SSHProfile?,
                          targetAuth: NIOSSHClientUserAuthenticationDelegate,
                          jumpAuth: NIOSSHClientUserAuthenticationDelegate?,
                          group: EventLoopGroup,
                          connectTimeout: TimeAmount? = nil) async throws -> Established {
        guard let jumpProfile, let jumpAuth else {
            let conn = try await connectSocket(host: profile.host, port: profile.port,
                                               auth: targetAuth, group: group,
                                               connectTimeout: connectTimeout)
            return Established(rootChannel: conn, carrierChannel: conn)
        }

        // 1) TCP + NIOSSH 连到跳板。
        let jumpConn = try await connectSocket(host: jumpProfile.host, port: jumpProfile.port,
                                               auth: jumpAuth, group: group,
                                               connectTimeout: connectTimeout)

        // 2) 在跳板连接上开 direct-tcpip 子通道，叠加目标 NIOSSHHandler。
        //    createChannel 只能在连接事件循环上调用（线程安全要求，同 SSHClient.openShell 注释）；
        //    子通道 promise 在跳板认证完成、远端同意转发后才兑现，认证失败则连同失败。
        // 发起方地址：协议要求携带，对本机到跳板方向无实际语义，用本机回环占位。
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        do {
            let carrier = try await jumpConn.pipeline.handler(type: NIOSSHHandler.self).flatMap { jumpHandler in
                let promise = jumpConn.eventLoop.makePromise(of: Channel.self)
                let directTCPIP = SSHChannelType.DirectTCPIP(
                    targetHost: profile.host,
                    targetPort: profile.port,
                    originatorAddress: originator
                )
                jumpHandler.createChannel(promise, channelType: .directTCPIP(directTCPIP)) { child, channelType in
                    guard case .directTCPIP = channelType else {
                        return child.eventLoop.makeFailedFuture(SSHCarrierError.unexpectedChannelType)
                    }
                    return child.eventLoop.makeCompletedFuture {
                        // 顺序：适配层在前、目标 SSH 在后——入站 SSHChannelData 先剥壳成
                        // ByteBuffer 再喂给 NIOSSHHandler，出站反向。
                        try child.pipeline.syncOperations.addHandlers([
                            SSHChannelDataByteAdapter(),
                            NIOSSHHandler(
                                role: .client(.init(userAuthDelegate: targetAuth,
                                                    serverAuthDelegate: CarrierAcceptAllHostKeysDelegate())),
                                allocator: child.allocator,
                                inboundChildChannelInitializer: nil
                            ),
                        ])
                    }
                }
                return promise.futureResult
            }.get()
            return Established(rootChannel: jumpConn, carrierChannel: carrier)
        } catch {
            // 子通道建立失败（跳板认证失败 / 跳板拒绝转发）时回收跳板 TCP 连接。
            jumpConn.close(mode: .all, promise: nil)
            throw error
        }
    }

    /// TCP socket + NIOSSHHandler（与原三处引擎各自的 bootstrap 一致：地址复用 + 全放行主机密钥，
    /// 真正的主机校验由调用方在连接前按 host:port TOFU 完成）。
    private static func connectSocket(host: String,
                                      port: Int,
                                      auth: NIOSSHClientUserAuthenticationDelegate,
                                      group: EventLoopGroup,
                                      connectTimeout: TimeAmount?) async throws -> Channel {
        var bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: auth,
                                            serverAuthDelegate: CarrierAcceptAllHostKeysDelegate())),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                }
            }
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        if let connectTimeout {
            bootstrap = bootstrap.connectTimeout(connectTimeout)
        }
        return try await bootstrap.connect(host: host, port: port).get()
    }
}

// MARK: - NIO 侧类型

/// direct-tcpip 子通道（I/O 为 SSHChannelData）与叠加其上的目标 NIOSSHHandler（I/O 为
/// ByteBuffer）之间的字节搬运。与 swift-nio-ssh 官方 PortForwardingServer 示例中的
/// SSHWrapperHandler 同构；direct-tcpip 只会收到 .channel 数据，其余类型（理论不会出现）丢弃。
nonisolated final class SSHChannelDataByteAdapter: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    nonisolated func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .channel = channelData.type,
              case .byteBuffer(let buffer) = channelData.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    nonisolated func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }
}

/// 主机密钥已在连接前按 host:port 维度完成 TOFU 询问，故此处直接放行。
private nonisolated final class CarrierAcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    nonisolated func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

private enum SSHCarrierError: Error {
    case unexpectedChannelType
}
