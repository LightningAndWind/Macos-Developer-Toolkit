//
//  ToolRegistration.swift
//  devkit
//
//  集中注册所有可用工具。新工具在此处新增一行即可插拔接入。
//

import Foundation

@MainActor
enum ToolRegistration {
    static func registerAll() {
        let registry = ToolRegistry.shared
        registry.register(descriptor: HTTPTool.descriptor) { HTTPTool() }
        registry.register(descriptor: SSHTool.descriptor) { SSHTool() }
        registry.register(descriptor: JSONTool.descriptor) { JSONTool() }
    }
}
