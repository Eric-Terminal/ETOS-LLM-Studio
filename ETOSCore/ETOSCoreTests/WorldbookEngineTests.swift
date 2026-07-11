// ============================================================================
// WorldbookEngineTests.swift
// ============================================================================
// WorldbookEngineTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

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

    @Test("常驻条目跳过关键词但仍遵守酒馆定时与概率规则")
    func testConstantEntriesSkipKeywordsButRespectTimedAndProbabilityRules() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-constant-every-turn-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0.5 })
        let delayed = WorldbookEntry(
            content: "等待消息数的常驻设定",
            keys: [],
            constant: true,
            position: .after,
            delay: 2
        )
        let probabilistic = WorldbookEntry(
            content: "未通过概率的常驻设定",
            keys: [],
            constant: true,
            position: .after,
            useProbability: true,
            probability: 0
        )
        let book = Worldbook(name: "常驻书", entries: [delayed, probabilistic])
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
                messages: [
                    ChatMessage(role: .user, content: "依旧没有关键词"),
                    ChatMessage(role: .assistant, content: "第二条消息")
                ],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(!first.after.contains(where: { $0.content == "等待消息数的常驻设定" }))
        #expect(second.after.contains(where: { $0.content == "等待消息数的常驻设定" }))
        #expect(!first.after.contains(where: { $0.content == "未通过概率的常驻设定" }))
        #expect(!second.after.contains(where: { $0.content == "未通过概率的常驻设定" }))
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
                messages: [
                    ChatMessage(role: .user, content: "apple banana hello"),
                    ChatMessage(role: .assistant, content: "no keyword")
                ],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(second.after.contains(where: { $0.content.contains("粘性") }))

        let third = engine.evaluate(
            .init(
                sessionID: sessionID,
                worldbooks: [book],
                messages: [
                    ChatMessage(role: .user, content: "apple banana hello"),
                    ChatMessage(role: .assistant, content: "no keyword"),
                    ChatMessage(role: .user, content: "still no keyword")
                ],
                topicPrompt: nil,
                enhancedPrompt: nil
            )
        )

        #expect(!third.after.contains(where: { $0.content.contains("粘性") }))
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

    @Test("engine enforces explicit per-book entry and character budgets")
    func testInjectedEntryBudgetSuppressesLowerPriorityEntries() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-per-book-budget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let book = Worldbook(
            name: "显式预算裁剪",
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
        #expect(!result.after.contains(where: { $0.content == "budget-second-hit" }))
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

    @Test("engine selects one weighted winner from the same inclusion group")
    func testGroupSelectsSingleWinner() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-group-scope-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let runtime = WorldbookRuntimeStateStore(storageURL: tempURL)
        let engine = WorldbookEngine(runtimeStore: runtime, randomSource: { 0 })

        let book = Worldbook(
            name: "同组条目选出一个",
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
        #expect(!result.after.contains(where: { $0.content == "group-low-hit" }))
    }

    @Test("engine gives group override priority over weighted selection")
    func testGroupOverrideWins() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-group-override-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let engine = WorldbookEngine(
            runtimeStore: WorldbookRuntimeStateStore(storageURL: tempURL),
            randomSource: { 0 }
        )
        let book = Worldbook(
            name: "组优先级",
            entries: [
                WorldbookEntry(content: "普通高权重", keys: ["hero"], order: 100, group: "route", groupWeight: 100),
                WorldbookEntry(content: "强制优先", keys: ["hero"], order: 10, group: "route", groupOverride: true, groupWeight: 1)
            ]
        )

        let result = engine.evaluate(.init(
            sessionID: UUID(),
            worldbooks: [book],
            messages: [ChatMessage(role: .user, content: "hero")],
            topicPrompt: nil,
            enhancedPrompt: nil
        ))

        #expect(result.after.map(\.content) == ["强制优先"])
    }

    @Test("engine parses SillyTavern slash-delimited regex keyword flags")
    func testSlashDelimitedRegexKeyword() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-regex-literal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let engine = WorldbookEngine(runtimeStore: WorldbookRuntimeStateStore(storageURL: tempURL), randomSource: { 0 })
        let entry = WorldbookEntry(
            content: "regex-hit",
            keys: [#"/^hero\s+arrives$/im"#],
            useRegex: true
        )
        let book = Worldbook(name: "正则关键词", entries: [entry])

        let result = engine.evaluate(.init(
            sessionID: UUID(),
            worldbooks: [book],
            messages: [ChatMessage(role: .user, content: "前文\nHero arrives\n后文")],
            topicPrompt: nil,
            enhancedPrompt: nil
        ))

        #expect(result.after.contains(where: { $0.content == "regex-hit" }))
    }

    @Test("ignoreBudget metadata bypasses explicit budgets")
    func testIgnoreBudgetMetadata() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-ignore-budget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let engine = WorldbookEngine(runtimeStore: WorldbookRuntimeStateStore(storageURL: tempURL), randomSource: { 0 })
        let book = Worldbook(
            name: "预算豁免",
            entries: [
                WorldbookEntry(content: "normal", keys: ["hero"], order: 100),
                WorldbookEntry(
                    content: "ignore-budget",
                    keys: ["hero"],
                    order: 90,
                    metadata: ["ignoreBudget": .bool(true)]
                )
            ],
            settings: WorldbookSettings(maxInjectedEntries: 1, maxInjectedCharacters: 6)
        )

        let result = engine.evaluate(.init(
            sessionID: UUID(),
            worldbooks: [book],
            messages: [ChatMessage(role: .user, content: "hero")],
            topicPrompt: nil,
            enhancedPrompt: nil
        ))

        #expect(result.after.contains(where: { $0.content == "normal" }))
        #expect(result.after.contains(where: { $0.content == "ignore-budget" }))
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
            delay: 2
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

        let second = engine.evaluate(.init(
            sessionID: sessionID,
            worldbooks: [book],
            messages: [
                ChatMessage(role: .user, content: "trigger"),
                ChatMessage(role: .assistant, content: "second message")
            ],
            topicPrompt: nil,
            enhancedPrompt: nil
        ))
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

    @Test("最小激活数会把扫描深度扩展到配置上限")
    func testMinimumActivationsExpandScanDepth() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-minimum-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let engine = WorldbookEngine(
            runtimeStore: WorldbookRuntimeStateStore(storageURL: tempURL),
            randomSource: { 0 }
        )
        let entry = WorldbookEntry(content: "深层激活", keys: ["旧线索"])
        let book = Worldbook(
            name: "最小激活",
            entries: [entry],
            settings: .init(scanDepth: 1),
            metadata: ["min_activations": .int(1), "min_activations_depth_max": .int(3)]
        )

        let result = engine.evaluate(.init(
            sessionID: UUID(),
            worldbooks: [book],
            messages: [
                ChatMessage(role: .user, content: "旧线索"),
                ChatMessage(role: .assistant, content: "中间回复"),
                ChatMessage(role: .user, content: "最新消息")
            ]
        ))

        #expect(result.after.map(\.content) == ["深层激活"])
    }

    @Test("条目可扫描 Persona 与角色资料并接受外部向量激活")
    func testContextAndVectorActivation() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-runtime-context-vector-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let engine = WorldbookEngine(
            runtimeStore: WorldbookRuntimeStateStore(storageURL: tempURL),
            randomSource: { 0 }
        )
        let persona = WorldbookEntry(
            content: "Persona 命中",
            keys: ["北方旅人"],
            metadata: ["extensions": .dictionary(["match_persona_description": .bool(true)])]
        )
        let vector = WorldbookEntry(
            content: "向量命中",
            keys: ["不会出现的关键词"],
            metadata: ["extensions": .dictionary(["vectorized": .bool(true)])]
        )
        let scenario = WorldbookEntry(
            content: "场景命中",
            keys: ["海边车站"],
            metadata: ["extensions": .dictionary(["match_scenario": .bool(true)])]
        )
        let book = Worldbook(name: "上下文与向量", entries: [persona, vector, scenario])

        let result = engine.evaluate(.init(
            sessionID: UUID(),
            worldbooks: [book],
            messages: [ChatMessage(role: .user, content: "普通消息")],
            personaDescription: "来自北方旅人家族",
            scenario: "故事发生在海边车站",
            vectorActivatedEntryIDs: [vector.id]
        ))

        #expect(Set(result.after.map(\.content)) == ["Persona 命中", "向量命中", "场景命中"])
    }

    @Test("向量匹配在系统嵌入不可用时仍可通过本地向量回退激活")
    func testVectorMatcherFallback() async {
        let matching = WorldbookEntry(content: "海边车站与北方旅人", keys: [])
        let unrelated = WorldbookEntry(content: "量子处理器性能参数", keys: [])
        let matcher = WorldbookVectorMatcher()

        let activated = await matcher.activatedEntryIDs(
            entries: [matching, unrelated],
            query: "海边车站与北方旅人",
            maximumEntries: 1,
            scoreThreshold: 0.2
        )

        #expect(activated == [matching.id])
    }
}
