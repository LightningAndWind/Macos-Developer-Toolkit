//
//  SFTPProtocol.swift
//  devkit
//
//  SFTP v3 线上协议的最小编解码：包头（长度前缀）+ 包类型 + 各操作的 payload。
//  只实现 SFTPTool 需要的操作子集：INIT/VERSION、REALPATH、OPENDIR/READDIR/CLOSE、
//  OPEN/READ/WRITE、STAT/LSTAT、MKDIR/RMDIR/REMOVE/RENAME。
//
//  协议参考 draft-ietf-secsh-filexfer-02（版本 3），字节序一律大端。
//

import Foundation

// MARK: - 包类型

/// SFTP v3 包类型字节。
enum SFTPPacketType: UInt8 {
    case initialize   = 1
    case version      = 2
    case open         = 3
    case close        = 4
    case read         = 5
    case write        = 6
    case lstat        = 7
    case opendir      = 11
    case readdir      = 12
    case remove       = 13
    case mkdir        = 14
    case rmdir        = 15
    case realpath     = 16
    case stat         = 17
    case rename       = 18
    case status       = 101
    case handle       = 102
    case data         = 103
    case name         = 104
    case attrs        = 105
}

/// STATUS 包的状态码（v3）。
enum SFTPStatusCode: UInt32 {
    case ok            = 0
    case eof           = 1
    case noSuchFile    = 2
    case permissionDenied = 3
    case failure       = 4
    case badMessage    = 5
    case noConnection  = 6
    case connectionLost = 7
    case opUnsupported = 8
}

// MARK: - 字节编解码原语

/// 大端字节写出器。
struct SFTPWriter {
    private(set) var bytes: [UInt8] = []

    mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func writeUInt64(_ value: UInt64) {
        writeUInt32(UInt32((value >> 32) & 0xFFFF_FFFF))
        writeUInt32(UInt32(value & 0xFFFF_FFFF))
    }

    mutating func writeString(_ string: String) {
        let data = Array(string.utf8)
        writeUInt32(UInt32(data.count))
        bytes.append(contentsOf: data)
    }

    mutating func writeBytes(_ data: [UInt8]) {
        writeUInt32(UInt32(data.count))
        bytes.append(contentsOf: data)
    }

    mutating func writeRaw(_ data: [UInt8]) {
        bytes.append(contentsOf: data)
    }
}

/// 大端字节读取器；越界抛 `SFTPError.invalidPacket`。
struct SFTPReader {
    let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPError.invalidPacket }
        let v = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        offset += 4
        return v
    }

    mutating func readUInt64() throws -> UInt64 {
        try UInt64(readUInt32()) << 32 | UInt64(readUInt32())
    }

    mutating func readString() throws -> String {
        let count = Int(try readUInt32())
        guard remaining >= count else { throw SFTPError.invalidPacket }
        let s = String(decoding: bytes[offset..<(offset + count)], as: UTF8.self)
        offset += count
        return s
    }

    mutating func readBytes() throws -> [UInt8] {
        let count = Int(try readUInt32())
        guard remaining >= count else { throw SFTPError.invalidPacket }
        let data = Array(bytes[offset..<(offset + count)])
        offset += count
        return data
    }
}

// MARK: - 文件属性

/// ATTRS 结构（v3）。仅解码；写路径只用到「空 attrs」（mkdir 用）。
struct SFTPAttrs: Equatable {
    /// flags 位。
    private static let flagSize = UInt32(0x1)
    private static let flagUIDGID = UInt32(0x2)
    private static let flagPermissions = UInt32(0x4)
    private static let flagACModTime = UInt32(0x8)
    private static let flagExtended = UInt32(0x8000_0000)

    var size: UInt64?
    var permissions: UInt32?
    var mtime: UInt32?

    /// 文件权限位布局（POSIX）。
    private static let typeMask = UInt32(0o170000)
    private static let dirFlag = UInt32(0o040000)
    private static let linkFlag = UInt32(0o120000)

    var isDirectory: Bool {
        guard let p = permissions else { return false }
        return p & Self.typeMask == Self.dirFlag
    }

    var isLink: Bool {
        guard let p = permissions else { return false }
        return p & Self.typeMask == Self.linkFlag
    }

    var isRegularFile: Bool {
        guard let p = permissions else { return false }
        return p & Self.typeMask == 0o100000
    }

    static func decode(from reader: inout SFTPReader) throws -> SFTPAttrs {
        let flags = try reader.readUInt32()
        var attrs = SFTPAttrs()
        if flags & flagSize != 0 { attrs.size = try reader.readUInt64() }
        if flags & flagUIDGID != 0 {
            _ = try reader.readUInt32() // uid
            _ = try reader.readUInt32() // gid
        }
        if flags & flagPermissions != 0 { attrs.permissions = try reader.readUInt32() }
        if flags & flagACModTime != 0 {
            _ = try reader.readUInt32() // atime
            attrs.mtime = try reader.readUInt32()
        }
        if flags & flagExtended != 0 {
            let count = Int(try reader.readUInt32())
            for _ in 0..<max(0, count) {
                _ = try reader.readString()
                _ = try reader.readString()
            }
        }
        return attrs
    }

    /// 空 attrs（flags=0），MKDIR/RMDIR 等操作需要携带。
    static func encodeEmpty(into writer: inout SFTPWriter) {
        writer.writeUInt32(0)
    }
}

// MARK: - 目录条目

/// READDIR 返回的一个条目（NAME 包的一项）。
struct SFTPEntry: Identifiable, Equatable {
    let name: String
    let longName: String
    let attrs: SFTPAttrs

    var id: String { name }
    var isDirectory: Bool { attrs.isDirectory }
}

// MARK: - 应答包

/// 一次请求的应答（已按包类型解析）。
enum SFTPReply {
    case status(code: UInt32, message: String)
    case handle([UInt8])
    case data([UInt8])
    case name([(name: String, longName: String, attrs: SFTPAttrs)])
    case attrs(SFTPAttrs)
    case version(UInt32)
}

// MARK: - 错误

enum SFTPError: LocalizedError {
    case invalidPacket
    case connectionClosed
    case serverError(code: UInt32, message: String)
    case unsupportedReply(UInt8)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidPacket:
            return "收到无法解析的 SFTP 数据包"
        case .connectionClosed:
            return "SFTP 连接已断开"
        case .serverError(_, let message):
            return message.isEmpty ? "SFTP 操作失败" : message
        case .unsupportedReply(let type):
            return "收到不支持的数据包类型 \(type)"
        case .timedOut:
            return "SFTP 请求超时"
        }
    }

    /// 把 STATUS 包转成错误；`ok`/`eof` 返回 nil 表示成功语义。
    static func fromStatus(code: UInt32, message: String) -> SFTPError? {
        guard code != SFTPStatusCode.ok.rawValue, code != SFTPStatusCode.eof.rawValue else { return nil }
        return .serverError(code: code, message: message)
    }
}

// MARK: - 应答解释

extension SFTPReply {
    /// 期望 STATUS OK（write/close/mkdir/remove/rmdir/rename）。
    func expectOK() throws {
        switch self {
        case .status(let code, let message):
            if let error = SFTPError.fromStatus(code: code, message: message) { throw error }
        default:
            throw SFTPError.invalidPacket
        }
    }

    /// 期望 HANDLE（open/opendir）。
    func expectHandle() throws -> [UInt8] {
        switch self {
        case .handle(let handle):
            return handle
        case .status(let code, let message):
            if let error = SFTPError.fromStatus(code: code, message: message) { throw error }
            throw SFTPError.invalidPacket
        default:
            throw SFTPError.invalidPacket
        }
    }

    /// 期望 DATA（read）；EOF 回报 nil。
    func expectData() throws -> [UInt8]? {
        switch self {
        case .data(let data):
            return data
        case .status(let code, let message):
            if let error = SFTPError.fromStatus(code: code, message: message) { throw error }
            return nil // EOF
        default:
            throw SFTPError.invalidPacket
        }
    }

    /// 期望 NAME（readdir/realpath）；EOF 回报 nil。
    func expectNameList() throws -> [(name: String, longName: String, attrs: SFTPAttrs)]? {
        switch self {
        case .name(let items):
            return items
        case .status(let code, let message):
            if let error = SFTPError.fromStatus(code: code, message: message) { throw error }
            return nil // EOF
        default:
            throw SFTPError.invalidPacket
        }
    }

    /// 期望 ATTRS（stat/lstat）。
    func expectAttrs() throws -> SFTPAttrs {
        switch self {
        case .attrs(let attrs):
            return attrs
        case .status(let code, let message):
            if let error = SFTPError.fromStatus(code: code, message: message) { throw error }
            throw SFTPError.invalidPacket
        default:
            throw SFTPError.invalidPacket
        }
    }
}
