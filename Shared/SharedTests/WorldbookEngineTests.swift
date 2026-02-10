import Testing
import Foundation
@testable import Shared

@Suite("Worldbook Engine Tests")
struct WorldbookEngineTests {

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

    @Test("engine applies group scoring and group override")
    func testEngineGroupRules() {
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
        #expect(!result.after.contains(where: { $0.content == "score loser" }))
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
}
