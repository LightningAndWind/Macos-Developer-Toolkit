//
//  JSONValue.swift
//  devkit
//
//  M3 JSON 工具：保序的 JSON 值模型 + 统计 + 键排序。
//  用有序成员数组而非字典，保留键插入顺序、允许重复键，并使数字以原始字面量保存不被改写精度。
//

import Foundation

/// 一个 JSON 对象成员（键 + 值），保持插入顺序。
struct JSONMember {
    var key: String
    var value: JSONValue
}

/// 递归 JSON 值模型。数字存原始字符串以免浮点往返丢精度；对象保序。
indirect enum JSONValue {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    // MARK: - 便捷判定

    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    var childMembers: [JSONMember]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var childValues: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    /// 类型中文名，用于状态栏与树视图标签。
    var typeLabel: String {
        switch self {
        case .object: return "对象"
        case .array:  return "数组"
        case .string: return "字符串"
        case .number: return "数字"
        case .bool:   return "布尔"
        case .null:   return "null"
        }
    }

    /// 标量值的可读文本（树视图叶子展示用）。
    var scalarDisplay: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return n
        case .bool(let b):   return b ? "true" : "false"
        case .null:          return "null"
        case .object(let m): return "{\(m.count)}"
        case .array(let a):  return "[\(a.count)]"
        }
    }

    // MARK: - 统计

    /// 文档概览统计：节点数、最大深度、各类型分布。
    struct Stats: Equatable {
        var nodeCount: Int = 0
        var maxDepth: Int = 0
        var objectCount: Int = 0
        var arrayCount: Int = 0
        var stringCount: Int = 0
        var numberCount: Int = 0
        var boolCount: Int = 0
        var nullCount: Int = 0

        /// 把一个子树统计并入当前：节点/类型计数累加，深度取子树最大深度 +1。
        mutating func merge(child: Stats) {
            nodeCount += child.nodeCount
            objectCount += child.objectCount
            arrayCount += child.arrayCount
            stringCount += child.stringCount
            numberCount += child.numberCount
            boolCount += child.boolCount
            nullCount += child.nullCount
            maxDepth = max(maxDepth, child.maxDepth + 1)
        }
    }

    /// 以本节点为根的子树统计。深度：标量为 0，容器为 1 + 子树最大深度。
    var stats: Stats {
        switch self {
        case .object(let members):
            var acc = Stats(nodeCount: 1, objectCount: 1)
            for member in members { acc.merge(child: member.value.stats) }
            return acc
        case .array(let values):
            var acc = Stats(nodeCount: 1, arrayCount: 1)
            for value in values { acc.merge(child: value.stats) }
            return acc
        case .string: return Stats(nodeCount: 1, stringCount: 1)
        case .number: return Stats(nodeCount: 1, numberCount: 1)
        case .bool:   return Stats(nodeCount: 1, boolCount: 1)
        case .null:   return Stats(nodeCount: 1, nullCount: 1)
        }
    }

    // MARK: - 键排序

    /// 递归（或仅顶层）按键名排序对象成员；数组元素顺序保持不变，仅其内部对象受影响（递归时）。
    func sortedKeys(ascending: Bool = true, recursive: Bool = true) -> JSONValue {
        switch self {
        case .object(let members):
            let sorted = members.sorted { a, b in
                let ordered = a.key.localizedCaseInsensitiveCompare(b.key) == .orderedAscending
                return ascending ? ordered : !ordered
            }
            let mapped = sorted.map { JSONMember(key: $0.key,
                                                 value: recursive ? $0.value.sortedKeys(ascending: ascending, recursive: true) : $0.value) }
            return .object(mapped)
        case .array(let values):
            guard recursive else { return .array(values) }
            return .array(values.map { $0.sortedKeys(ascending: ascending, recursive: true) })
        default:
            return self
        }
    }

    /// 容器子项数量（对象成员数 / 数组元素数）；标量为 0。
    var childCount: Int {
        switch self {
        case .object(let m): return m.count
        case .array(let a):  return a.count
        default: return 0
        }
    }
}
