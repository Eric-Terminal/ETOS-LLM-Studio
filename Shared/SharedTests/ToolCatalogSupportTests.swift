// ============================================================================
// ToolCatalogSupportTests.swift
// ============================================================================
// ToolCatalogSupportTests 测试文件
// - 覆盖内置工具状态汇总
// - 覆盖 Schema 摘要生成逻辑
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("工具中心辅助测试")
struct ToolCatalogSupportTests {

    @Test("世界书隔离会影响内置工具的当前会话可用性")
    func testBuiltInToolStatesReflectIsolation() {
        let states = ToolCatalogSupport.builtInToolStates(
            enableMemory: true,
            enableMemoryWrite: true,
            enableMemoryActiveRetrieval: true,
            memoryTopK: 5,
            isIsolatedSession: true
        )

        let memoryWrite = states.first(where: { $0.kind == .memoryWrite })
        let memorySearch = states.first(where: { $0.kind == .memorySearch })

        #expect(memoryWrite?.isConfiguredEnabled == true)
        #expect(memoryWrite?.isAvailableInCurrentSession == false)
        #expect(memoryWrite?.statusReason == .isolatedByWorldbook)
        #expect(memorySearch?.isConfiguredEnabled == true)
        #expect(memorySearch?.isAvailableInCurrentSession == false)
        #expect(memorySearch?.statusReason == .isolatedByWorldbook)
    }

    @Test("Top K 为零时主动检索不会视为启用")
    func testBuiltInToolStatesReflectZeroTopK() {
        let states = ToolCatalogSupport.builtInToolStates(
            enableMemory: true,
            enableMemoryWrite: true,
            enableMemoryActiveRetrieval: true,
            memoryTopK: 0,
            isIsolatedSession: false
        )

        let memorySearch = states.first(where: { $0.kind == .memorySearch })

        #expect(memorySearch?.isConfiguredEnabled == false)
        #expect(memorySearch?.isAvailableInCurrentSession == false)
        #expect(memorySearch?.statusReason == .zeroTopK)
    }

    @Test("Schema 摘要会提取字段与必填项")
    func testSchemaSummaryIncludesFieldsAndRequiredKeys() {
        let schema = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "query": .dictionary(["type": .string("string")]),
                "count": .dictionary(["type": .string("integer")])
            ]),
            "required": .array([.string("query")])
        ])

        let summary = ToolCatalogSupport.schemaSummary(for: schema, fieldLimit: 4)

        #expect(summary == "type=object · fields=count, query · required=query")
    }
}
