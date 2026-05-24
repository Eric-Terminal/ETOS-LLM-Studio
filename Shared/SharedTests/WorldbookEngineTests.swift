// ============================================================================
// WorldbookEngineTests.swift
// ============================================================================
// WorldbookEngineTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("Worldbook Engine Tests")
struct WorldbookEngineTests {

    @Test("默认世界书注入预算不限制")
    func testDefaultWorldbookInjectionBudgetsUnlimited() {
        let settings = WorldbookSettings()

        #expect(settings.maxInjectedEntries == -1)
        #expect(settings.maxInjectedCharacters == -1)
    }

    @Test("默认世界书注入不会限制 64 条")
    func testDefaultWorldbookInjectionDoesNotCapAtSixtyFourEntries() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-default-unlimited-entries-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })
        let entries = (0..<80).map { index in
            WorldbookEntry(
                content: "默认无限条目 \(index)",
                keys: ["常驻"],
                position: .after,
                order: 100 - index
            )
        }
        let book = Worldbook(name: "默认无限注入测试", entries: entries)

        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "常驻")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.after.count == 80)
    }

    @Test("常驻激活条目每轮注入且不受触发规则阻挡")
    func testConstantEntriesInjectEveryTurnWithoutTriggerRules() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-constant-every-turn-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 1 })
        let entry = WorldbookEntry(
            content: "常驻设定",
            keys: [],
            constant: true,
            position: .after,
            useProbability: true,
            probability: 0,
            cooldown: 99,
            delay: 99,
            preventRecursion: true,
            delayUntilRecursion: true
        )
        let book = Worldbook(name: "常驻书", entries: [entry])
        let sessionID = UUID()

        let first = engine.evaluate(
            .init(
                sessionID: sessionID,
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "没有关键词")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )
        let second = engine.evaluate(
            .init(
                sessionID: sessionID,
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "依旧没有关键词")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(first.after.contains(where: { $0.content == "常驻设定" }))
        #expect(second.after.contains(where: { $0.content == "常驻设定" }))
    }

    @Test("engine handles secondary logic, probability and sticky")
    func testEngineCoreRules() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0.5 })

        let always = WorldbookEntry(
            comment: "主键命中",
            content: "这是 Apple 规则",
            keys: ["apple"],
            position: .after,
            order: 10
        )

        let andAll = WorldbookEntry(
            comment: "二级逻辑",
            content: "需要 apple + banana",
            keys: ["apple"],
            secondaryKeys: ["banana", "candy"],
            selectiveLogic: .notAny,
            position: .after,
            order: 20
        )

        let probabilistic = WorldbookEntry(
            comment: "概率规则",
            content: "不应命中",
            keys: ["apple"],
            position: .after,
            order: 30,
            useProbability: true,
            probability: 0,
        )

        let sticky = WorldbookEntry(
            comment: "sticky",
            content: "粘性条目",
            keys: ["hello"],
            position: .after,
            order: 40,
            sticky: 2
        )

        let book = Worldbook(
            name: "规则测试",
            entries: [always, andAll, probabilistic, sticky],
            settings: WorldbookSettings(scanDepth: 4, maxRecursionDepth: 1, maxInjectedEntries: 20, maxInjectedCharacters: 9999)
        )

        let sessionID = UUID()
        let first = engine.evaluate(
            .init(
                sessionID: sessionID,
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "apple banana hello")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(first.after.contains(where: { $0.content.contains("Apple") }))
        #expect(first.after.contains(where: { $0.content.contains("粘性") }))
        #expect(!first.after.contains(where: { $0.content.contains("不应命中") }))

        // NOT_ANY + secondary [banana, candy]，当前包含 banana，因此不应该触发
        #expect(!first.after.contains(where: { $0.content.contains("apple + banana") }))

        let second = engine.evaluate(
            .init(
                sessionID: sessionID,
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "no keyword")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(second.after.contains(where: { $0.content.contains("粘性") }))
    }

    @Test("engine treats negative injected character budget as unlimited")
    func testNegativeInjectedCharacterBudgetIsUnlimited() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-unlimited-budget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })
        let longContent = String(repeating: "设定", count: 200)
        let entry = WorldbookEntry(
            content: longContent,
            keys: ["无限"],
            position: .after
        )
        let book = Worldbook(
            name: "无限预算测试",
            entries: [entry],
            settings: WorldbookSettings(maxInjectedEntries: 1, maxInjectedCharacters: -1)
        )

        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "无限")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.after.contains(where: { $0.content == longContent }))
    }

    @Test("engine ignores injected entry budget when entries match")
    func testInjectedEntryBudgetDoesNotSuppressMatchedEntries() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-per-book-budget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let book = Worldbook(
            name: "显式预算不裁剪",
            entries: [
                WorldbookEntry(content: "budget-first-hit", keys: ["hero"], position: .after, order: 100),
                WorldbookEntry(content: "budget-second-hit", keys: ["hero"], position: .after, order: 90)
            ],
            settings: WorldbookSettings(maxInjectedEntries: 1, maxInjectedCharacters: 10)
        )

        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "hero")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.after.contains(where: { $0.content == "budget-first-hit" }))
        #expect(result.after.contains(where: { $0.content == "budget-second-hit" }))
    }

    @Test("engine keeps matching entries when different worldbooks reuse entry IDs")
    func testEntryIDCollisionAcrossWorldbooksDoesNotSuppressMatches() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-entry-id-collision-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let sharedEntryID = UUID()
        let firstBook = Worldbook(
            name: "复用 ID 一本",
            entries: [WorldbookEntry(id: sharedEntryID, content: "same-entry-id-first", keys: ["hero"], position: .after)]
        )
        let secondBook = Worldbook(
            name: "复用 ID 二本",
            entries: [WorldbookEntry(id: sharedEntryID, content: "same-entry-id-second", keys: ["hero"], position: .after)]
        )

        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [firstBook, secondBook],
                messages: [ChatMessage(role: .user, content: "hero")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.after.contains(where: { $0.content == "same-entry-id-first" }))
        #expect(result.after.contains(where: { $0.content == "same-entry-id-second" }))
    }

    @Test("engine keeps all matching entries in the same group")
    func testGroupDoesNotSuppressMatchingEntries() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-group-scope-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let book = Worldbook(
            name: "同组条目全部发送",
            entries: [
                WorldbookEntry(content: "group-high-hit", keys: ["hero"], order: 100, group: "shared"),
                WorldbookEntry(content: "group-low-hit", keys: ["hero"], order: 10, group: "shared")
            ]
        )

        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "hero")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.after.contains(where: { $0.content == "group-high-hit" }))
        #expect(result.after.contains(where: { $0.content == "group-low-hit" }))
    }

    @Test("engine supports atDepth / emTop / emBottom positions")
    func testEnginePositions() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-position-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let depthEntry = WorldbookEntry(content: "depth", keys: ["k"], position: .atDepth, depth: 2)
        let emTopEntry = WorldbookEntry(content: "emtop", keys: ["k"], position: .emTop)
        let emBottomEntry = WorldbookEntry(content: "embottom", keys: ["k"], position: .emBottom)

        let outletEntry = WorldbookEntry(content: "outlet", keys: ["k"], position: .outlet, outletName: "character_sheet")
        let book = Worldbook(name: "位置书", entries: [depthEntry, emTopEntry, emBottomEntry, outletEntry])

        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "k")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.emTop.contains(where: { $0.content == "emtop" }))
        #expect(result.emBottom.contains(where: { $0.content == "embottom" }))
        #expect(result.atDepth.contains(where: { $0.depth == 2 }))
        #expect(result.outlet.contains(where: { $0.outletName == "character_sheet" && $0.content == "outlet" }))
    }

    @Test("engine ignores worldbook-level enabled switch and relies on binding + entry toggles")
    func testEngineIgnoresWorldbookEnabledSwitch() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-book-enabled-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let entry = WorldbookEntry(
            comment: "禁用书也应触发",
            content: "book-level switch ignored",
            keys: ["trigger"],
            isEnabled: true,
            position: .after
        )
        let book = Worldbook(
            name: "book-level switch",
            isEnabled: false,
            entries: [entry]
        )

        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "trigger")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.after.contains(where: { $0.content == "book-level switch ignored" }))
    }

    @Test("engine supports all secondary selective logic branches")
    func testEngineSecondarySelectiveLogicMatrix() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-secondary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let andAny = WorldbookEntry(
            comment: "andAny",
            content: "AND_ANY 命中",
            keys: ["hero"],
            secondaryKeys: ["red", "blue"],
            selectiveLogic: .andAny
        )
        let andAll = WorldbookEntry(
            comment: "andAll",
            content: "AND_ALL 命中",
            keys: ["hero"],
            secondaryKeys: ["red", "blue"],
            selectiveLogic: .andAll
        )
        let notAny = WorldbookEntry(
            comment: "notAny",
            content: "NOT_ANY 命中",
            keys: ["hero"],
            secondaryKeys: ["red", "blue"],
            selectiveLogic: .notAny
        )
        let notAll = WorldbookEntry(
            comment: "notAll",
            content: "NOT_ALL 命中",
            keys: ["hero"],
            secondaryKeys: ["red", "blue"],
            selectiveLogic: .notAll
        )
        let book = Worldbook(name: "secondary", entries: [andAny, andAll, notAny, notAll])

        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "hero red")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.after.contains(where: { $0.content == "AND_ANY 命中" }))
        #expect(!result.after.contains(where: { $0.content == "AND_ALL 命中" }))
        #expect(!result.after.contains(where: { $0.content == "NOT_ANY 命中" }))
        #expect(result.after.contains(where: { $0.content == "NOT_ALL 命中" }))
    }

    @Test("导入的 selective 开关关闭时引擎忽略次级关键词")
    func testEngineIgnoresSecondaryKeysWhenSelectiveIsOff() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-secondary-selective-off-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let importedEntry = WorldbookEntry(
            content: "selective-off primary hit",
            keys: ["hero"],
            secondaryKeys: ["missing-secondary"],
            selectiveLogic: .andAny,
            metadata: [WorldbookMetadataKey.etosSecondaryKeysEnabled: .bool(false)]
        )
        let nativeEntry = WorldbookEntry(
            content: "native secondary still checked",
            keys: ["hero"],
            secondaryKeys: ["missing-secondary"],
            selectiveLogic: .andAny
        )
        let legacyImportedEntry = WorldbookEntry(
            content: "legacy metadata primary hit",
            keys: ["hero"],
            secondaryKeys: ["missing-secondary"],
            selectiveLogic: .andAny,
            metadata: [WorldbookMetadataKey.sillyTavernSecondaryKeys: .array([.string("missing-secondary")])]
        )
        let book = Worldbook(name: "selective", entries: [importedEntry, legacyImportedEntry, nativeEntry])

        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "hero")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.after.contains(where: { $0.content == "selective-off primary hit" }))
        #expect(result.after.contains(where: { $0.content == "legacy metadata primary hit" }))
        #expect(!result.after.contains(where: { $0.content == "native secondary still checked" }))
    }

    @Test("engine ignores group scoring and keeps every matching group entry")
    func testEngineGroupFieldsDoNotSuppressEntries() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-group-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let winnerByScore = WorldbookEntry(
            comment: "winner",
            content: "score winner",
            keys: ["hero", "ruby"],
            order: 10,
            group: "g1",
            groupWeight: 1,
            useGroupScoring: true
        )
        let loserByScore = WorldbookEntry(
            comment: "loser",
            content: "score loser",
            keys: ["hero"],
            order: 10,
            group: "g1",
            groupWeight: 6,
            useGroupScoring: true
        )
        let alwaysKeep = WorldbookEntry(
            comment: "override",
            content: "group override keep",
            keys: ["hero"],
            order: 11,
            group: "g1",
            groupOverride: true
        )
        let book = Worldbook(name: "group", entries: [winnerByScore, loserByScore, alwaysKeep])

        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "hero ruby")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.after.contains(where: { $0.content == "score winner" }))
        #expect(result.after.contains(where: { $0.content == "score loser" }))
        #expect(result.after.contains(where: { $0.content == "group override keep" }))
    }

    @Test("engine supports recursion and entry-level scanDepth override")
    func testEngineRecursionAndScanDepthOverride() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-recursion-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let recursionSource = WorldbookEntry(
            content: "龙裔设定: dragon",
            keys: ["spark"],
            position: .after,
            order: 1
        )
        let recursionConsumer = WorldbookEntry(
            content: "recursion hit",
            keys: ["dragon"],
            position: .after,
            order: 2,
            delayUntilRecursion: true
        )
        let scanDepthOverride = WorldbookEntry(
            content: "should not hit ancient",
            keys: ["ancient"],
            position: .after,
            order: 3,
            scanDepth: 1
        )
        let book = Worldbook(
            name: "recursion",
            entries: [recursionSource, recursionConsumer, scanDepthOverride],
            settings: WorldbookSettings(scanDepth: 6, maxRecursionDepth: 2, maxInjectedEntries: 20, maxInjectedCharacters: 9999)
        )

        let messages = [
            ChatMessage(role: .user, content: "ancient"),
            ChatMessage(role: .assistant, content: "older answer"),
            ChatMessage(role: .user, content: "spark")
        ]
        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [book],
                messages: messages,
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.after.contains(where: { $0.content == "龙裔设定: dragon" }))
        #expect(result.after.contains(where: { $0.content == "recursion hit" }))
        #expect(!result.after.contains(where: { $0.content == "should not hit ancient" }))
    }

    @Test("engine scan depth counts recent messages instead of user assistant pairs")
    func testEngineScanDepthCountsMessages() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-message-scan-depth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let recentOnly = WorldbookEntry(
            content: "recent hit",
            keys: ["recent"],
            position: .after,
            scanDepth: 2
        )
        let older = WorldbookEntry(
            content: "older should not hit",
            keys: ["older"],
            position: .after,
            scanDepth: 2
        )
        let book = Worldbook(name: "扫描深度", entries: [recentOnly, older])
        let messages = [
            ChatMessage(role: .user, content: "older"),
            ChatMessage(role: .assistant, content: "middle"),
            ChatMessage(role: .user, content: "recent")
        ]

        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [book],
                messages: messages,
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.after.contains(where: { $0.content == "recent hit" }))
        #expect(!result.after.contains(where: { $0.content == "older should not hit" }))
    }

    @Test("engine handles delay and cooldown")
    func testEngineDelayAndCooldown() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-delay-cooldown-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let delayed = WorldbookEntry(
            content: "delayed",
            keys: ["trigger"],
            position: .after,
            delay: 1
        )
        let cooldown = WorldbookEntry(
            content: "cooldown",
            keys: ["trigger"],
            position: .after,
            cooldown: 2
        )
        let book = Worldbook(name: "定时书", entries: [delayed, cooldown])
        let sessionID = UUID()

        let first = engine.evaluate(.init(sessionID: sessionID, worldbooks: [book], messages: [ChatMessage(role: .user, content: "trigger")], topicPrompt: nil, enhancedPrompt: nil))
        #expect(!first.after.contains(where: { $0.content == "delayed" }))
        #expect(first.after.contains(where: { $0.content == "cooldown" }))

        let second = engine.evaluate(.init(sessionID: sessionID, worldbooks: [book], messages: [ChatMessage(role: .user, content: "trigger")], topicPrompt: nil, enhancedPrompt: nil))
        #expect(second.after.contains(where: { $0.content == "delayed" }))
        #expect(!second.after.contains(where: { $0.content == "cooldown" }))
    }

    @Test("engine sorts matched entries by priority descending")
    func testEnginePriorityDescending() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-priority-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let high = WorldbookEntry(content: "high", keys: ["trigger"], position: .after, order: 999)
        let low = WorldbookEntry(content: "low", keys: ["trigger"], position: .after, order: 1)
        let book = Worldbook(name: "优先级", entries: [low, high])

        let result = engine.evaluate(
            .init(
                sessionID: UUID(),
                worldbooks: [book],
                messages: [ChatMessage(role: .user, content: "trigger")],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(result.after.count == 2)
        #expect(result.after.first?.content == "high")
        #expect(result.after.last?.content == "low")
    }
}
