//
//  SSHHostKeyStore.swift
//  devkit
//
//  M4：主机密钥信任记录（TOFU）。首连询问、接受后按 host:port 落库；再连直接放行。
//  说明：NIOSSH 的 NIOSSHPublicKey 未公开可序列化的字节/指纹，故本期以「host:port 维度」
//  记录信任，无法持久化比对密钥指纹或检测变更；细粒度指纹校验留待后续（见 M4 限制说明）。
//

import Foundation

@MainActor
enum SSHHostKeyStore {
    /// 该 host:port 是否已被信任。
    static func isTrusted(host: String, port: Int) -> Bool {
        guard DatabaseManager.shared.isOpen else { return false }
        var trusted = false
        try? DatabaseManager.shared.query(
            "SELECT 1 FROM ssh_known_hosts WHERE host = ? AND port = ? LIMIT 1;",
            bind: [.text(host), .int(port)]
        ) { _ in
            trusted = true
            return false
        }
        return trusted
    }

    /// 记录信任（幂等）。key_type / key_blob 预留，本期不使用。
    static func trust(host: String, port: Int) {
        guard DatabaseManager.shared.isOpen else { return }
        try? DatabaseManager.shared.run(
            """
            INSERT INTO ssh_known_hosts(host, port, key_type, key_blob, added_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(host, port, key_type) DO UPDATE SET added_at = excluded.added_at;
            """,
            bind: [
                .text(host),
                .int(port),
                .text(""),
                .blob(Data()),
                .real(Date.now.timeIntervalSince1970),
            ]
        )
    }

    /// 撤销某 host 的全部信任（port 传 nil 表示所有端口）。
    static func revoke(host: String, port: Int?) {
        guard DatabaseManager.shared.isOpen else { return }
        if let port {
            try? DatabaseManager.shared.run("DELETE FROM ssh_known_hosts WHERE host = ? AND port = ?;",
                                            bind: [.text(host), .int(port)])
        } else {
            try? DatabaseManager.shared.run("DELETE FROM ssh_known_hosts WHERE host = ?;", bind: [.text(host)])
        }
    }
}
