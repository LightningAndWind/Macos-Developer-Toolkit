//
//  SSHAuthSupport.swift
//  devkit
//
//  SSH 认证委托的共享工厂：SSH 终端（SSHClient）与 SFTP（SFTPConnection）共用同一套
//  密码 / 私钥认证逻辑，避免两处复制后行为漂移。
//  从 SSHClient.swift 中抽出（原为 private）；私钥解析规则不变：仅支持未加密的
//  PKCS#8 PEM ECDSA（P-256/384/521），加密 PEM 与 OpenSSH 原生格式明确报不支持。
//

import Foundation
import CryptoKit
import NIOCore
import NIOSSH

@MainActor
enum SSHAuthSupport {
    /// 构造认证委托：密码用 NIOSSH 内置 SimplePasswordDelegate；私钥解析 PEM 后自定义。
    static func makeUserAuthDelegate(for profile: SSHProfile) throws -> NIOSSHClientUserAuthenticationDelegate {
        switch profile.authKind {
        case .password:
            return SimplePasswordDelegate(username: profile.username,
                                          password: profile.password ?? "")
        case .key:
            guard let fileName = profile.privateKeyFileName,
                  let url = SSHKeyStorage.resolvedURL(fileName: fileName) else {
                throw SSHClientError.privateKeyMissing
            }
            let pem = try String(contentsOf: url, encoding: .utf8)
            let key = try parsePrivateKey(pem: pem, passphrase: profile.keyPassphrase)
            return PrivateKeyAuthDelegate(username: profile.username, privateKey: key)
        }
    }

    /// 用 CryptoKit 解析 PEM（PKCS#8）私钥。本期仅支持未加密的 NIST ECDSA（P-256/384/521）PEM；
    /// 含口令的加密 PEM 与 OpenSSH 原生格式暂不支持（会抛出明确错误）。
    static nonisolated func parsePrivateKey(pem: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        _ = passphrase // 加密私钥暂不支持；unencrypted 解析失败即报不支持。
        if let k = try? P256.Signing.PrivateKey(pemRepresentation: pem) { return NIOSSHPrivateKey(p256Key: k) }
        if let k = try? P384.Signing.PrivateKey(pemRepresentation: pem) { return NIOSSHPrivateKey(p384Key: k) }
        if let k = try? P521.Signing.PrivateKey(pemRepresentation: pem) { return NIOSSHPrivateKey(p521Key: k) }
        throw SSHClientError.privateKeyUnsupported
    }
}

/// 私钥认证委托：提供一次 privateKey offer，之后返回 nil。
nonisolated final class PrivateKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private let lock = NSLock()
    nonisolated(unsafe) private var pending = true

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    nonisolated func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock(); let shouldOffer = pending && availableMethods.contains(.publicKey); pending = false; lock.unlock()
        if shouldOffer {
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: username, serviceName: "",
                                              offer: .privateKey(.init(privateKey: privateKey)))
            )
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}
