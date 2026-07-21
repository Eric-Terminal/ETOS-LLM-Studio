// ============================================================================
// ETOSCoreModelConfigurationTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责模型提示词、模型排序与请求体覆盖配置测试。
// ============================================================================

import Testing
import Foundation
import SwiftUI
@testable import ETOSCore

@Suite("模型用途配置")
struct ModelKindConfigurationTests {
    @Test("普通模型只提供聊天、图片生成和嵌入三种用途")
    func exposesOnlyPrimaryModelKinds() {
        #expect(ModelKind.allCases == [.chat, .image, .embedding])
    }
}

@Suite("聊天颜色偏好编解码")
struct ChatAppearanceColorCodecTests {
    @Test("支持解析 6 位十六进制并默认不透明")
    func parsesRGBHexWithOpaqueAlpha() {
        let color = ChatAppearanceColorCodec.color(from: "3D8FF2", fallback: .black)
        let rgba = ChatAppearanceColorCodec.rgbaComponents(from: color)

        #expect(rgba != nil)
        #expect(abs((rgba?.red ?? 0) - 0.239) < 0.01)
        #expect(abs((rgba?.green ?? 0) - 0.561) < 0.01)
        #expect(abs((rgba?.blue ?? 0) - 0.949) < 0.01)
        #expect(abs((rgba?.alpha ?? 0) - 1.0) < 0.001)
    }

    @Test("Color 与十六进制 RGBA 可往返")
    func supportsRoundTripBetweenColorAndHex() {
        let original = Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6, opacity: 0.8)
        let encoded = ChatAppearanceColorCodec.hexRGBA(from: original)

        #expect(encoded == "336699CC")

        let decoded = ChatAppearanceColorCodec.color(from: encoded ?? "", fallback: .clear)
        let rgba = ChatAppearanceColorCodec.rgbaComponents(from: decoded)

        #expect(rgba != nil)
        #expect(abs((rgba?.red ?? 0) - 0.2) < 0.01)
        #expect(abs((rgba?.green ?? 0) - 0.4) < 0.01)
        #expect(abs((rgba?.blue ?? 0) - 0.6) < 0.01)
        #expect(abs((rgba?.alpha ?? 0) - 0.8) < 0.01)
    }

    @Test("变暗处理仅缩放 RGB 并保持 Alpha")
    func darkenedKeepsAlpha() {
        let original = Color(.sRGB, red: 0.8, green: 0.5, blue: 0.3, opacity: 0.4)
        let darkened = ChatAppearanceColorCodec.darkened(original, factor: 0.5)
        let rgba = ChatAppearanceColorCodec.rgbaComponents(from: darkened)

        #expect(rgba != nil)
        #expect(abs((rgba?.red ?? 0) - 0.4) < 0.01)
        #expect(abs((rgba?.green ?? 0) - 0.25) < 0.01)
        #expect(abs((rgba?.blue ?? 0) - 0.15) < 0.01)
        #expect(abs((rgba?.alpha ?? 0) - 0.4) < 0.01)
    }

    @Test("替换透明度时保留 RGB 并钳制 Alpha")
    func replacingAlphaKeepsRGB() {
        let original = Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6, opacity: 0.8)
        let adjusted = ChatAppearanceColorCodec.replacingAlpha(of: original, with: 1.4)
        let rgba = ChatAppearanceColorCodec.rgbaComponents(from: adjusted)

        #expect(rgba != nil)
        #expect(abs((rgba?.red ?? 0) - 0.2) < 0.01)
        #expect(abs((rgba?.green ?? 0) - 0.4) < 0.01)
        #expect(abs((rgba?.blue ?? 0) - 0.6) < 0.01)
        #expect(abs((rgba?.alpha ?? 0) - 1.0) < 0.001)
    }
}

@Suite("MainstreamModelFamily Tests")
struct MainstreamModelFamilyTests {
    @Test("按模型ID识别主流模型家族")
    func testDetectByModelName() {
        #expect(MainstreamModelFamily.detect(modelName: "gpt-4o") == .chatgpt)
        #expect(MainstreamModelFamily.detect(modelName: "gemini-2.5-pro") == .gemini)
        #expect(MainstreamModelFamily.detect(modelName: "claude-3-7-sonnet") == .claude)
        #expect(MainstreamModelFamily.detect(modelName: "deepseek-chat") == .deepseek)
        #expect(MainstreamModelFamily.detect(modelName: "qwen-max") == .qwen)
        #expect(MainstreamModelFamily.detect(modelName: "moonshot-v1-8k") == .kimi)
        #expect(MainstreamModelFamily.detect(modelName: "doubao-seed-1.6") == .doubao)
        #expect(MainstreamModelFamily.detect(modelName: "grok-3") == .grok)
        #expect(MainstreamModelFamily.detect(modelName: "meta-llama/llama-3.1-8b-instruct") == .llama)
        #expect(MainstreamModelFamily.detect(modelName: "mixtral-8x7b-instruct") == .mistral)
        #expect(MainstreamModelFamily.detect(modelName: "glm-4-plus") == .glm)
    }

    @Test("按显示名识别主流模型家族")
    func testDetectByDisplayName() {
        #expect(MainstreamModelFamily.detect(modelName: "custom-model", displayName: "ChatGPT 企业版") == .chatgpt)
        #expect(MainstreamModelFamily.detect(modelName: "custom-model", displayName: "豆包 Pro") == .doubao)
    }

    @Test("未知模型识别为其他")
    func testUnknownModelReturnsNil() {
        #expect(MainstreamModelFamily.detect(modelName: "my-private-model") == nil)
    }
}

@Suite("Provider Active Model Order Tests")
struct ProviderActiveModelOrderTests {
    private func makeModel(_ name: String, active: Bool) -> Model {
        Model(modelName: name, displayName: name, isActivated: active)
    }

    @Test("仅重排已添加模型，未添加模型位置保持不变")
    func testMoveActivatedModelsKeepsInactiveOrder() {
        var provider = Provider(
            name: "Test",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                makeModel("a", active: true),
                makeModel("x", active: false),
                makeModel("b", active: true),
                makeModel("c", active: true),
                makeModel("y", active: false)
            ]
        )

        provider.moveActivatedModels(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        #expect(provider.models.map(\.modelName) == ["b", "x", "c", "a", "y"])
        #expect(provider.models.filter(\.isActivated).map(\.modelName) == ["b", "c", "a"])
    }

    @Test("非法拖拽索引不会改动模型顺序")
    func testMoveActivatedModelsWithInvalidOffsetsNoChange() {
        var provider = Provider(
            name: "Test",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                makeModel("a", active: true),
                makeModel("x", active: false),
                makeModel("b", active: true)
            ]
        )
        let original = provider.models.map(\.modelName)

        provider.moveActivatedModels(fromOffsets: IndexSet(integer: 10), toOffset: 1)

        #expect(provider.models.map(\.modelName) == original)
    }

    @Test("按位置移动已添加模型")
    func testMoveActivatedModelByPosition() {
        var provider = Provider(
            name: "Test",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                makeModel("a", active: true),
                makeModel("x", active: false),
                makeModel("b", active: true),
                makeModel("c", active: true),
                makeModel("y", active: false)
            ]
        )

        provider.moveActivatedModel(fromPosition: 2, toPosition: 0)

        #expect(provider.models.map(\.modelName) == ["c", "x", "a", "b", "y"])
    }
}

@Suite("ModelOrderIndex Tests")
struct ModelOrderIndexTests {
    @Test("合并隐藏索引时保留旧顺序并追加新增模型")
    func testMergeOrderKeepsStoredThenAppendsNew() {
        let stored = ["p1-m2", "p2-m1", "removed", "p1-m2"]
        let current = ["p1-m1", "p1-m2", "p2-m1", "p3-m1"]

        let merged = ModelOrderIndex.merge(storedIDs: stored, currentIDs: current)

        #expect(merged == ["p1-m2", "p2-m1", "p1-m1", "p3-m1"])
    }

    @Test("按位置移动隐藏索引")
    func testMoveOrderByPosition() {
        let ids = ["a", "b", "c", "d"]

        let moved = ModelOrderIndex.move(ids: ids, fromPosition: 3, toPosition: 1)

        #expect(moved == ["a", "d", "b", "c"])
    }

    @Test("分层排序先遵循提供商顺序并保留内部模型顺序")
    func hierarchicalOrderUsesProviderThenModelOrder() {
        let current = ["p1-m1", "p1-m2", "p2-m1", "p2-m2"]
        let providerByModel = [
            "p1-m1": "p1",
            "p1-m2": "p1",
            "p2-m1": "p2",
            "p2-m2": "p2"
        ]

        let ordered = ModelOrderIndex.hierarchicalOrder(
            storedModelIDs: ["p1-m2", "p2-m2", "p1-m1", "p2-m1"],
            currentModelIDs: current,
            providerIDByModelID: providerByModel,
            orderedProviderIDs: ["p2", "p1"]
        )

        #expect(ordered == ["p2-m2", "p2-m1", "p1-m2", "p1-m1"])
    }
}

@Suite("RunnableModelGrouping Tests")
struct RunnableModelGroupingTests {
    @Test("提供商缩写识别分词、驼峰、全大写与中文拼音")
    func providerMonogramRecognizesNamingStyles() {
        #expect(ProviderMonogram.abbreviation(for: "FoxCode") == "FC")
        #expect(ProviderMonogram.abbreviation(for: "NVIDIA") == "NV")
        #expect(ProviderMonogram.abbreviation(for: "ETOS API") == "EA")
        #expect(ProviderMonogram.abbreviation(for: "硅基流动") == "GJ")
    }

    @Test("按提供商顺序分组并保留组内模型顺序")
    func groupsModelsByConfiguredProviderOrder() {
        let providerAID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let providerBID = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let modelA1 = Model(modelName: "a-1", displayName: "A 1", isActivated: true)
        let modelA2 = Model(modelName: "a-2", displayName: "A 2", isActivated: true)
        let modelB1 = Model(modelName: "b-1", displayName: "B 1", isActivated: true)
        let providerA = Provider(
            id: providerAID,
            name: "Alpha",
            baseURL: "https://alpha.example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [modelA1, modelA2]
        )
        let providerB = Provider(
            id: providerBID,
            name: "Beta",
            baseURL: "https://beta.example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [modelB1]
        )
        let models = [
            RunnableModel(provider: providerA, model: modelA2),
            RunnableModel(provider: providerB, model: modelB1),
            RunnableModel(provider: providerA, model: modelA1)
        ]

        let groups = RunnableModelGrouping.groups(
            models: models,
            providerOrder: [providerB, providerA]
        )

        #expect(groups.map(\.id) == [providerBID, providerAID])
        #expect(groups[0].models.map(\.model.modelName) == ["b-1"])
        #expect(groups[1].models.map(\.model.modelName) == ["a-2", "a-1"])
    }

    @Test("模型选择分组保留未分类、分组与组内模型顺序")
    func pickerLayoutPreservesConfiguredOrder() {
        let models = [
            Model(modelName: "ungrouped-1", isActivated: true),
            Model(modelName: "claude-1", pickerGroupName: " Claude ", isActivated: true),
            Model(modelName: "openai-1", pickerGroupName: "OpenAI", isActivated: true),
            Model(modelName: "ungrouped-2", pickerGroupName: "  ", isActivated: true),
            Model(modelName: "claude-2", pickerGroupName: "Claude", isActivated: true)
        ]
        let provider = Provider(
            name: "Example",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: models
        )

        let layout = RunnableModelPickerGrouping.layout(
            models: models.map { RunnableModel(provider: provider, model: $0) }
        )

        #expect(layout.ungroupedModels.map(\.model.modelName) == ["ungrouped-1", "ungrouped-2"])
        #expect(layout.groups.map(\.name) == ["Claude", "OpenAI"])
        #expect(layout.groups[0].models.map(\.model.modelName) == ["claude-1", "claude-2"])
        #expect(layout.groups[1].models.map(\.model.modelName) == ["openai-1"])
    }

    @Test("模型可以拖入文件夹并拖回根目录")
    func pickerOrganizationMovesModelsAcrossFolderBoundary() {
        let provider = Provider(
            name: "Example",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "root-a", isActivated: true),
                Model(modelName: "folder-b1", pickerGroupName: "Folder", isActivated: true),
                Model(modelName: "folder-b2", pickerGroupName: "Folder", isActivated: true),
                Model(modelName: "root-c", isActivated: true)
            ]
        )
        let models = provider.models.map { RunnableModel(provider: provider, model: $0) }
        let idByName = Dictionary(uniqueKeysWithValues: models.map { ($0.model.modelName, $0.id) })
        var organization = RunnableModelPickerOrganization(models: models)

        organization.moveModel(
            idByName["root-a"]!,
            intoGroup: "Folder",
            beforeModelID: idByName["folder-b2"]!
        )

        #expect(organization.placements.map(\.modelID) == [
            idByName["folder-b1"]!,
            idByName["root-a"]!,
            idByName["folder-b2"]!,
            idByName["root-c"]!
        ])
        #expect(organization.placements.map(\.pickerGroupName) == [
            "Folder", "Folder", "Folder", nil
        ])

        organization.moveModelToRoot(
            idByName["folder-b1"]!,
            beforeRootItemID: RunnableModelPickerOrganization.RootItem.modelID(
                idByName["root-c"]!
            )
        )

        #expect(organization.placements.map(\.modelID) == [
            idByName["root-a"]!,
            idByName["folder-b2"]!,
            idByName["folder-b1"]!,
            idByName["root-c"]!
        ])
        #expect(organization.placements.map(\.pickerGroupName) == [
            "Folder", "Folder", nil, nil
        ])
    }

    @Test("文件夹和文件夹内模型可以独立排序")
    func pickerOrganizationReordersFoldersAndChildren() {
        let provider = Provider(
            name: "Example",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "root-a", isActivated: true),
                Model(modelName: "folder-b1", pickerGroupName: "Folder", isActivated: true),
                Model(modelName: "folder-b2", pickerGroupName: "Folder", isActivated: true),
                Model(modelName: "other-d", pickerGroupName: "Other", isActivated: true)
            ]
        )
        let models = provider.models.map { RunnableModel(provider: provider, model: $0) }
        let idByName = Dictionary(uniqueKeysWithValues: models.map { ($0.model.modelName, $0.id) })
        var organization = RunnableModelPickerOrganization(models: models)

        organization.moveGroup(
            "Other",
            beforeRootItemID: RunnableModelPickerOrganization.RootItem.modelID(
                idByName["root-a"]!
            )
        )
        organization.reorderModels(
            inGroup: "Folder",
            orderedModelIDs: [idByName["folder-b2"]!, idByName["folder-b1"]!]
        )

        #expect(organization.rootItems.map(\.id) == [
            RunnableModelPickerOrganization.RootItem.groupID("Other"),
            RunnableModelPickerOrganization.RootItem.modelID(idByName["root-a"]!),
            RunnableModelPickerOrganization.RootItem.groupID("Folder")
        ])
        #expect(organization.placements.map(\.modelID) == [
            idByName["other-d"]!,
            idByName["root-a"]!,
            idByName["folder-b2"]!,
            idByName["folder-b1"]!
        ])
    }

    @Test("文件夹可以嵌套并保持完整目录路径")
    func pickerOrganizationNestsFolders() {
        let provider = Provider(
            name: "Example",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "folder-a", pickerGroupName: "Folder", isActivated: true),
                Model(modelName: "child-b", pickerGroupName: "Folder/Child", isActivated: true),
                Model(modelName: "other-c", pickerGroupName: "Other", isActivated: true)
            ]
        )
        let models = provider.models.map { RunnableModel(provider: provider, model: $0) }
        var organization = RunnableModelPickerOrganization(models: models)

        #expect(organization.allGroupPaths == ["Folder", "Folder/Child", "Other"])

        organization.moveGroup("Folder", intoGroup: "Other")

        #expect(organization.allGroupPaths == [
            "Other",
            "Other/Folder",
            "Other/Folder/Child"
        ])
        #expect(organization.placements.map(\.pickerGroupName) == [
            "Other",
            "Other/Folder",
            "Other/Folder/Child"
        ])

        let unchangedPlacements = organization.placements
        organization.moveGroup("Other", intoGroup: "Other/Folder")
        #expect(organization.placements == unchangedPlacements)
    }

    @Test("嵌套目录会映射为递归模型选择布局")
    func pickerLayoutBuildsNestedFolders() {
        let models = [
            Model(modelName: "parent", pickerGroupName: "Tools", isActivated: true),
            Model(modelName: "child", pickerGroupName: "Tools/Coding", isActivated: true)
        ]
        let provider = Provider(
            name: "Example",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: models
        )

        let layout = RunnableModelPickerGrouping.layout(
            models: models.map { RunnableModel(provider: provider, model: $0) }
        )

        #expect(layout.groups.map(\.path) == ["Tools"])
        #expect(layout.groups.first?.models.map(\.model.modelName) == ["parent", "child"])
        guard let parent = layout.groups.first,
              case .group(let childFolder) = parent.items.last else {
            Issue.record("缺少嵌套文件夹")
            return
        }
        #expect(childFolder.path == "Tools/Coding")
        #expect(childFolder.models.map(\.model.modelName) == ["child"])
    }

    @Test("空文件夹可以创建、嵌套并在模型移出后保留")
    func pickerOrganizationKeepsEmptyFolders() {
        let provider = Provider(
            name: "Example",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "nested", pickerGroupName: "Tools/Coding", isActivated: true)
            ]
        )
        let models = provider.models.map { RunnableModel(provider: provider, model: $0) }
        var organization = RunnableModelPickerOrganization(
            models: models,
            groupPaths: ["Empty", "Tools/Coding"]
        )

        organization.createGroup("Empty/Child")
        organization.moveModelToRoot(models[0].id)

        #expect(organization.orderedGroupPaths == [
            "Tools",
            "Tools/Coding",
            "Empty",
            "Empty/Child"
        ])
        #expect(organization.placements == [
            RunnableModelPickerPlacement(modelID: models[0].id, pickerGroupName: nil)
        ])
    }

    @Test("空文件夹与模型的混合顺序可以恢复")
    func pickerOrganizationRestoresMixedItemOrder() {
        let provider = Provider(
            name: "Example",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "root-a", isActivated: true),
                Model(modelName: "folder-b", pickerGroupName: "Folder", isActivated: true),
                Model(modelName: "root-c", isActivated: true)
            ]
        )
        let models = provider.models.map { RunnableModel(provider: provider, model: $0) }
        let idByName = Dictionary(uniqueKeysWithValues: models.map { ($0.model.modelName, $0.id) })
        var organization = RunnableModelPickerOrganization(
            models: models,
            groupPaths: ["Empty", "Folder"]
        )

        organization.moveGroup(
            "Empty",
            beforeRootItemID: RunnableModelPickerOrganization.RootItem.modelID(
                idByName["root-a"]!
            )
        )
        let restored = RunnableModelPickerOrganization(
            models: models,
            groupPaths: organization.orderedGroupPaths,
            itemOrderIDs: organization.orderedItemIDs
        )

        #expect(restored.rootItems.map(\.id) == organization.rootItems.map(\.id))
        #expect(restored.orderedItemIDs == organization.orderedItemIDs)
    }

    @Test("文件夹边界决定模型归属并允许嵌套")
    func pickerOrganizationAppliesFolderBoundaries() {
        let provider = Provider(
            name: "Example",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "root-a", isActivated: true),
                Model(modelName: "root-b", isActivated: true),
                Model(modelName: "root-c", isActivated: true)
            ]
        )
        let models = provider.models.map { RunnableModel(provider: provider, model: $0) }
        var organization = RunnableModelPickerOrganization(models: models)
        organization.createGroup("A")
        organization.createGroup("B")

        let reordered: [RunnableModelPickerOrganization.BoundaryItem] = [
            .groupStart("A"),
            .model(models[0].id),
            .groupStart("B"),
            .model(models[1].id),
            .groupEnd("B"),
            .model(models[2].id),
            .groupEnd("A")
        ]
        let updated = organization.applyingBoundaryItems(reordered)

        #expect(updated?.orderedGroupPaths == ["A", "A/B"])
        #expect(updated?.placements.map(\.pickerGroupName) == ["A", "A/B", "A"])
    }

    @Test("文件夹边界不能交叉")
    func pickerOrganizationRejectsCrossedFolderBoundaries() {
        let provider = Provider(
            name: "Example",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "root", isActivated: true)]
        )
        let models = provider.models.map { RunnableModel(provider: provider, model: $0) }
        var organization = RunnableModelPickerOrganization(models: models)
        organization.createGroup("A")
        organization.createGroup("B")

        let crossed: [RunnableModelPickerOrganization.BoundaryItem] = [
            .groupStart("A"),
            .groupStart("B"),
            .model(models[0].id),
            .groupEnd("A"),
            .groupEnd("B")
        ]

        #expect(organization.applyingBoundaryItems(crossed) == nil)
    }

    @Test("删除文件夹会成对移除边界并保留内部条目")
    func pickerOrganizationRemovesFolderBoundariesAndKeepsContents() {
        let provider = Provider(
            name: "Example",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                Model(modelName: "direct", pickerGroupName: "A", isActivated: true),
                Model(modelName: "nested", pickerGroupName: "A/Child", isActivated: true),
                Model(modelName: "root", isActivated: true)
            ]
        )
        let models = provider.models.map { RunnableModel(provider: provider, model: $0) }
        let organization = RunnableModelPickerOrganization(models: models)

        let updated = organization.removingGroup("A")

        #expect(updated?.orderedGroupPaths == ["Child"])
        #expect(updated?.placements.map(\.modelID) == models.map(\.id))
        #expect(updated?.placements.map(\.pickerGroupName) == [nil, "Child", nil])
        #expect(updated?.boundaryItems.contains(.groupStart("A")) == false)
        #expect(updated?.boundaryItems.contains(.groupEnd("A")) == false)
    }
}

@Suite("Provider Order Tests")
struct ProviderOrderTests {
    @Test("提供商排序会保留用户顺序并追加新增提供商")
    func providerOrderKeepsStoredThenAppendsNew() {
        let rows = [
            makeProviderRow(id: "provider-b", name: "Beta"),
            makeProviderRow(id: "provider-a", name: "Alpha"),
            makeProviderRow(id: "provider-c", name: "Gamma")
        ]

        let orderedRows = ConfigLoader.applyStoredProviderOrder(
            to: rows,
            storedIDs: ["provider-c", "removed", "provider-a", "provider-c"]
        )

        #expect(orderedRows.map(\.id) == ["provider-c", "provider-a", "provider-b"])
    }

    @Test("没有用户顺序时提供商按名称稳定排序")
    func providerOrderFallsBackToNameSort() {
        let rows = [
            makeProviderRow(id: "provider-b", name: "Beta"),
            makeProviderRow(id: "provider-a", name: "Alpha")
        ]

        let orderedRows = ConfigLoader.applyStoredProviderOrder(to: rows, storedIDs: [])

        #expect(orderedRows.map(\.id) == ["provider-a", "provider-b"])
    }

    private func makeProviderRow(id: String, name: String) -> ConfigLoader.RelationalProviderRecord {
        ConfigLoader.RelationalProviderRecord(
            id: id,
            name: name,
            baseURL: "https://example.com",
            chatEndpointPath: Provider.defaultChatEndpointPath,
            apiFormat: "openai-compatible",
            proxyIsEnabled: nil,
            proxyType: nil,
            proxyHost: nil,
            proxyPort: nil,
            proxyUsername: nil,
            proxyPassword: nil,
            updatedAt: 0
        )
    }
}

@Suite("Request Body Override Mode Tests")
struct RequestBodyOverrideModeTests {
    @Test("原始 JSON 对象可解析为覆盖参数")
    func testParseRawJSONObject() throws {
        let rawJSON = """
        {
          "temperature": 0.7,
          "stream": true,
          "extra_body": {
            "abc": "123",
            "tags": ["x", 1, false]
          }
        }
        """
        let parsed = try ParameterExpressionParser.parseRawJSONObject(rawJSON)
        #expect(parsed["temperature"] == .double(0.7))
        #expect(parsed["stream"] == .bool(true))

        guard case .dictionary(let extraBody)? = parsed["extra_body"] else {
            Issue.record("extra_body 未按预期解析为对象")
            return
        }
        #expect(extraBody["abc"] == .string("123"))
        guard case .array(let tags)? = extraBody["tags"] else {
            Issue.record("extra_body.tags 未按预期解析为数组")
            return
        }
        #expect(tags.count == 3)
    }

    @Test("原始 JSON 顶层非对象时返回错误")
    func testParseRawJSONObjectRejectsNonObject() {
        do {
            _ = try ParameterExpressionParser.parseRawJSONObject("[1, 2, 3]")
            Issue.record("顶层为数组时应当解析失败")
        } catch {
            #expect(error.localizedDescription.contains("顶层必须是 JSON 对象"))
        }
    }

    @Test("表达式序列化可保留嵌套对象和空值")
    func testSerializeParametersPreservesNestedStructures() throws {
        let parameters: [String: JSONValue] = [
            "extra_body": .dictionary([
                "abc": .string("123"),
                "nested": .dictionary([
                    "flag": .bool(false),
                    "items": .array([.string("x"), .int(1), .null])
                ])
            ]),
            "temperature": .double(0.7)
        ]

        let serialized = ParameterExpressionParser.serialize(parameters: parameters)
        let reparsed = try serialized.map { try ParameterExpressionParser.parse($0) }
        let rebuilt = ParameterExpressionParser.buildParameters(from: reparsed)

        #expect(rebuilt == parameters)
    }

    @Test("参数模板保留多个键与嵌套结构但不复制值")
    func testSerializeParameterTemplatePreservesStructureOnly() throws {
        let parameters: [String: JSONValue] = [
            "reasoning_effort": .string("high"),
            "thinking": .dictionary([
                "type": .string("disabled")
            ])
        ]

        #expect(ParameterExpressionParser.serializeTemplate(parameters: parameters) == [
            "reasoning_effort=",
            "thinking={type=}"
        ])
        let rawTemplate = ParameterExpressionParser.serializeRawJSONTemplate(parameters: parameters)
        let parsedTemplate = try ParameterExpressionParser.parseRawJSONObject(rawTemplate)
        #expect(parsedTemplate["reasoning_effort"] == .null)
        #expect(parsedTemplate["thinking"] == .dictionary(["type": .null]))
    }

    @Test("结构化控制可写入本地对话模板参数")
    func testRequestBodyControlCanSetLocalChatTemplateKwargs() {
        let control = ModelRequestBodyControl(
            id: "thinking",
            title: "思考",
            kind: .toggle,
            isEnabled: true,
            defaultIsActive: true,
            payload: [
                "chat_template_kwargs": .dictionary([
                    "enable_thinking": .bool(false)
                ])
            ]
        )

        let parameters = ModelRequestBodyControlCompiler.effectiveOverrideParameters(
            base: ["temperature": .double(0.7)],
            controls: [control],
            state: ModelRequestBodyControlState()
        )

        #expect(parameters["temperature"] == .double(0.7))
        guard case .dictionary(let kwargs)? = parameters["chat_template_kwargs"] else {
            Issue.record("chat_template_kwargs 未按预期合并为对象")
            return
        }
        #expect(kwargs["enable_thinking"] == .bool(false))
    }

    @Test("Model 编解码保留请求体编辑模式和原始 JSON 文本")
    func testModelCodingPreservesRequestBodyMode() throws {
        let source = Model(
            modelName: "test-model",
            pickerGroupName: " Reasoning ",
            overrideParameters: ["temperature": .double(0.8)],
            requestBodyOverrideMode: .rawJSON,
            rawRequestBodyJSON: "{\"temperature\":0.8}"
        )
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(Model.self, from: data)

        #expect(decoded.requestBodyOverrideMode == .rawJSON)
        #expect(decoded.rawRequestBodyJSON == "{\"temperature\":0.8}")
        #expect(decoded.pickerGroupName == "Reasoning")
    }

    @Test("键值对编辑模式是默认请求体编辑模式")
    func testKeyValueModeIsDefaultRequestBodyMode() throws {
        let model = Model(modelName: "test-model")

        #expect(model.requestBodyOverrideMode == .keyValue)
    }

    @Test("旧配置缺少新字段时使用默认编辑模式")
    func testModelDecodingDefaultsForLegacyPayload() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000123",
          "modelName": "legacy-model",
          "isActivated": false
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(Model.self, from: data)

        #expect(decoded.requestBodyOverrideMode == .keyValue)
        #expect(decoded.rawRequestBodyJSON == nil)
        #expect(decoded.pickerGroupName == nil)
    }

    @Test("聊天模型默认开启工具调用")
    func testChatModelDefaultCapabilitiesEnableToolCalling() throws {
        let model = Model(modelName: "plain-chat")

        #expect(model.supportsToolCalling)
        #expect(model.supportsReasoning == false)
        #expect(model.supportsStreaming == false)
        #expect(model.supportsEmbedding == false)
    }

    @Test("聊天模型可单独声明嵌入能力")
    func testChatModelCanDeclareEmbeddingCapability() throws {
        let model = Model(
            modelName: "chat-with-embedding",
            capabilities: [ModelCapability.toolCalling, .embedding]
        )

        #expect(model.kind == .chat)
        #expect(model.isConversationModel)
        #expect(model.supportsEmbedding)
    }

    @Test("旧模型能力解码会迁移到新能力结构")
    func testLegacyModelCapabilitiesDecodeIntoNewShape() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000124",
          "modelName": "legacy-vision-image",
          "capabilities": ["chat", "toolCalling", "imageGeneration"]
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(Model.self, from: data)

        #expect(decoded.kind == .chat)
        #expect(decoded.capabilities.contains(.toolCalling))
        #expect(decoded.outputModalities.contains(.image))
        #expect(decoded.supportsImageGeneration)
    }

    @Test("旧语音能力解码后仍能通过便捷属性识别")
    func testLegacySpeechCapabilitiesRemainSelectable() throws {
        let speechJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000125",
          "modelName": "legacy-speech",
          "capabilities": ["speechToText"]
        }
        """
        let ttsJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000126",
          "modelName": "legacy-tts",
          "capabilities": ["textToSpeech"]
        }
        """

        let speechModel = try JSONDecoder().decode(Model.self, from: Data(speechJSON.utf8))
        let ttsModel = try JSONDecoder().decode(Model.self, from: Data(ttsJSON.utf8))

        #expect(speechModel.supportsSpeechToText)
        #expect(speechModel.inputModalities.contains(.audio))
        #expect(ttsModel.supportsTextToSpeech)
        #expect(ttsModel.outputModalities.contains(.audio))
    }

    @Test("模型输出模态不会保留文件")
    func testModelOutputModalitiesDropFile() throws {
        let model = Model(
            modelName: "file-output-test",
            outputModalities: [.text, .file]
        )
        #expect(model.outputModalities == [.text])

        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000127",
          "modelName": "legacy-file-output",
          "outputModalities": ["text", "file"]
        }
        """
        let decoded = try JSONDecoder().decode(Model.self, from: Data(json.utf8))
        #expect(decoded.outputModalities == [.text])
    }

    @Test("切换模型用途会重置默认能力形态")
    func testResetCapabilityShapeWhenChangingModelKind() throws {
        var model = Model(
            modelName: "hybrid-model",
            inputModalities: [.text, .image, .audio, .file],
            outputModalities: [.text, .image],
            capabilities: [.toolCalling, .reasoning, .streaming, .jsonMode]
        )

        model.resetCapabilityShape(for: .image)

        #expect(model.kind == .image)
        #expect(model.inputModalities == [.text, .image])
        #expect(model.outputModalities == [.image])
        #expect(model.capabilities.isEmpty)

        model.resetCapabilityShape(for: .chat)

        #expect(model.kind == .chat)
        #expect(model.inputModalities == [.text])
        #expect(model.outputModalities == [.text])
        #expect(model.capabilities == [.toolCalling])
    }

    @Test("旧模型可用名称推断补齐新能力结构")
    func testLegacyModelCanApplyInferredCapabilityHints() throws {
        let legacyImage = Model(modelName: "gpt-image-1").applyingInferredCapabilityHints()
        let legacyVision = Model(modelName: "gpt-4o").applyingInferredCapabilityHints()

        #expect(legacyImage.kind == .image)
        #expect(legacyImage.outputModalities.contains(.image))
        #expect(legacyImage.supportsImageGeneration)
        #expect(legacyVision.kind == .chat)
        #expect(legacyVision.inputModalities.contains(.image))
    }

    @Test("聊天图片输出与独立生图接口保持分离")
    func testChatImageOutputDoesNotUseDedicatedImageGenerationEndpoint() throws {
        let chatModel = Model(
            modelName: "chat-with-image-output",
            kind: .chat,
            outputModalities: [.text, .image]
        )
        let imageModel = Model(modelName: "image-model", kind: .image)

        #expect(chatModel.supportsImageGeneration)
        #expect(chatModel.usesDedicatedImageGenerationEndpoint == false)
        #expect(imageModel.usesDedicatedImageGenerationEndpoint)
    }
}
