//
//  SFTPBackend.swift
//  devkit
//
//  M6：SFTP 面板「数据源」抽象。一侧既可以是远端 SFTP 连接（SFTPConnection），
//  也可以是这台 Mac 的本地文件系统（LocalSFTPBackend）。视图与传输逻辑只依赖本协议，
//  从而本地 ⇄ 远端、本地 ⇄ 本地、远端 ⇄ 远端三种互传组合共用同一套目录浏览 / 传输代码。
//
//  路径统一为 POSIX 风格绝对路径（"/" 为根），与远端 SFTP 语义一致；本地实现负责 ~ 展开。
//

import Foundation

/// 后端连接状态（远端与本地共用一套语义）。
enum SFTPBackendState: Equatable {
    case idle
    case connecting
    case connected(host: String)
    case failed(String)
    case disconnected
}

/// 一侧面板的数据源：目录浏览 + 文件读写的统一接口。
/// 全部在主 actor 上调用（实现类均为 @MainActor）。
@MainActor
protocol SFTPBackend: AnyObject {
    var state: SFTPBackendState { get }
    var isConnected: Bool { get }

    /// 断开并释放资源（本地实现仅重置状态）。
    func disconnect()

    /// 把相对路径（如 "."）解析为绝对路径；本地实现将 "."/"" 映射到用户主目录。
    func resolvePath(_ path: String) async throws -> String

    /// 列目录（不含 "." / ".."）。
    func listDirectory(_ path: String) async throws -> [SFTPEntry]

    func makeDirectory(_ path: String) async throws
    func removeFile(_ path: String) async throws
    func removeDirectory(_ path: String) async throws

    /// 读取「对端」文件写入到给定的本地临时 URL（供中转上传使用）。
    func downloadFile(_ path: String,
                      to localURL: URL,
                      progress: ((UInt64, UInt64?) -> Void)?) async throws

    /// 把给定的本地 URL 写到「对端」路径。
    func uploadFile(from localURL: URL,
                    to path: String,
                    progress: ((UInt64, UInt64?) -> Void)?) async throws
}
