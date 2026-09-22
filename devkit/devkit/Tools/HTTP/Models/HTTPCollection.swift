//
//  HTTPCollection.swift
//  devkit
//
//  M5：HTTP「已保存请求 + 多级文件夹」集合的数据模型。
//  值类型，仅在 MainActor 上下文使用；请求本体复用 HTTPRequestModel 的 Codable。
//

import Foundation

/// 集合文件夹（支持多级）。`parentID == nil` 表示位于根。
struct HTTPFolder: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var parentID: UUID?
    var name: String
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

/// 一条已保存的 HTTP 请求。`folderID == nil` 表示位于根（与"未保存"由工具的 savedRequestID 区分）。
struct HTTPSavedRequest: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var folderID: UUID?
    var name: String
    var request: HTTPRequestModel
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

/// 集合树节点，供 UI（OutlineGroup）渲染。文件夹可含子文件夹与请求，请求为叶子。
struct HTTPCollectionNode: Identifiable {
    enum Kind {
        case folder(HTTPFolder)
        case request(HTTPSavedRequest)
    }

    var id: UUID
    var kind: Kind
    var children: [HTTPCollectionNode]?

    init(id: UUID, kind: Kind, children: [HTTPCollectionNode]? = nil) {
        self.id = id
        self.kind = kind
        self.children = children
    }

    var name: String {
        switch kind {
        case .folder(let f): return f.name
        case .request(let r): return r.name
        }
    }

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }
}
