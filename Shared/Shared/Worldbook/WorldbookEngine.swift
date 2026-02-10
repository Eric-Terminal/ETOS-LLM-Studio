// ============================================================================
// WorldbookEngine.swift
// ============================================================================
// 世界书激活引擎（首版）
//
// 支持：关键词与 secondary logic、概率、分组、递归、sticky/cooldown/delay、
// scanDepth 与位置输出（before/after/anTop/anBottom/atDepth/emTop/emBottom/outlet）。
// ============================================================================

import Foundation
import os.log

public struct WorldbookInjection: Hashable, Sendable {
    public var worldbookID: UUID
    public var worldbookName: String
    public var entryID: UUID
    public var entryComment: String
    public var content: String
    public var position: WorldbookPosition
    public var outletName: String?
    public var order: Int
    public var depth: Int?
    public var role: WorldbookEntryRole
    public var triggerScore: Double

    public init(
        worldbookID: UUID,
        worldbookName: String,
        entryID: UUID,
        entryComment: String,
        content: String,
        position: WorldbookPosition,
        outletName: String?,
        order: Int,
        depth: Int?,
        role: WorldbookEntryRole,
        triggerScore: Double
    ) {
        self.worldbookID = worldbookID
        self.worldbookName = worldbookName
        self.entryID = entryID
        self.entryComment = entryComment
        self.content = content
        self.position = position
        self.outletName = outletName
        self.order = order
        self.depth = depth
        self.role = role
        self.triggerScore = triggerScore
    }

    public var renderedContent: String {
        let trimmedComment = entryComment.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedComment.isEmpty {
            return content
        }
        return "[\(trimmedComment)]\n\(content)"
    }
}

public struct WorldbookDepthInsertion: Hashable, Sendable {
    public var depth: Int
    public var items: [WorldbookInjection]

    public init(depth: Int, items: [WorldbookInjection]) {
        self.depth = depth
        self.items = items
    }
}

public struct WorldbookEvaluationResult: Hashable, Sendable {
    public var before: [WorldbookInjection]
    public var after: [WorldbookInjection]
    public var anTop: [WorldbookInjection]
    public var anBottom: [WorldbookInjection]
    public var emTop: [WorldbookInjection]
    public var emBottom: [WorldbookInjection]
    public var atDepth: [WorldbookDepthInsertion]
    public var outlet: [WorldbookInjection]
    public var triggeredEntryIDs: [UUID]

    public static let empty = WorldbookEvaluationResult(
        before: [],
        after: [],
        anTop: [],
        anBottom: [],
        emTop: [],
        emBottom: [],
        atDepth: [],
        outlet: [],
        triggeredEntryIDs: []
    )
}

public final class WorldbookRuntimeStateStore {
    public static let shared = WorldbookRuntimeStateStore()

    private let queue = DispatchQueue(label: "com.ETOS.LLM.Studio.worldbook.runtime")
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "WorldbookRuntimeStateStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let customStorageURL: URL?

    private struct StoredEnvelope: Codable {
        var schemaVersion: Int
        var sessions: [String: SessionRuntimeState]
    }

    private struct SessionRuntimeState: Codable {
        var turn: Int
        var states: [String: WorldbookTimedEffectState]
    }

    private var cache: StoredEnvelope?

    public init(storageURL: URL? = nil) {
        self.customStorageURL = storageURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    private var storageURL: URL {
        if let customStorageURL {
            let dir = customStorageURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return customStorageURL
        }
        let root = WorldbookStore.shared.storageDirectory
        return root.appendingPathComponent("session_states.json")
    }

    public func nextTurn(for sessionID: UUID) -> Int {
        queue.sync {
            var envelope = loadEnvelopeUnlocked()
            let key = sessionID.uuidString
            var session = envelope.sessions[key] ?? SessionRuntimeState(turn: 0, states: [:])
            session.turn += 1
            envelope.sessions[key] = session
            saveEnvelopeUnlocked(envelope)
            return session.turn
        }
    }

    public func state(for sessionID: UUID, entryID: UUID) -> WorldbookTimedEffectState {
        queue.sync {
            let envelope = loadEnvelopeUnlocked()
            let sessionKey = sessionID.uuidString
            let entryKey = entryID.uuidString
            return envelope.sessions[sessionKey]?.states[entryKey] ?? WorldbookTimedEffectState()
        }
    }

    public func updateState(_ state: WorldbookTimedEffectState, for sessionID: UUID, entryID: UUID) {
        queue.sync {
            var envelope = loadEnvelopeUnlocked()
            let sessionKey = sessionID.uuidString
            let entryKey = entryID.uuidString
            var session = envelope.sessions[sessionKey] ?? SessionRuntimeState(turn: 0, states: [:])
            session.states[entryKey] = state
            envelope.sessions[sessionKey] = session
            saveEnvelopeUnlocked(envelope)
        }
    }

    private func loadEnvelopeUnlocked() -> StoredEnvelope {
        if let cache {
            return cache
        }

        WorldbookStore.shared.setupDirectoryIfNeeded()
        let fileURL = storageURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = StoredEnvelope(schemaVersion: 1, sessions: [:])
            cache = empty
            return empty
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try decoder.decode(StoredEnvelope.self, from: data)
            cache = envelope
            return envelope
        } catch {
            logger.error("读取世界书会话状态失败: \(error.localizedDescription, privacy: .public)")
            let empty = StoredEnvelope(schemaVersion: 1, sessions: [:])
            cache = empty
            return empty
        }
    }

    private func saveEnvelopeUnlocked(_ envelope: StoredEnvelope) {
        do {
            let data = try encoder.encode(envelope)
            try data.write(to: storageURL, options: [.atomicWrite, .completeFileProtection])
            cache = envelope
        } catch {
            logger.error("保存世界书会话状态失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}

public struct WorldbookEngine {
    public struct Context {
        public var sessionID: UUID
        public var worldbooks: [Worldbook]
        public var messages: [ChatMessage]
        public var topicPrompt: String?
        public var enhancedPrompt: String?

        public init(
            sessionID: UUID,
            worldbooks: [Worldbook],
            messages: [ChatMessage],
            topicPrompt: String?,
            enhancedPrompt: String?
        ) {
            self.sessionID = sessionID
            self.worldbooks = worldbooks
            self.messages = messages
            self.topicPrompt = topicPrompt
            self.enhancedPrompt = enhancedPrompt
        }
    }

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "WorldbookEngine")
    private let runtimeStore: WorldbookRuntimeStateStore
    private let randomSource: () -> Double

    public init(
        runtimeStore: WorldbookRuntimeStateStore = .shared,
        randomSource: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.runtimeStore = runtimeStore
        self.randomSource = randomSource
    }

    public func evaluate(_ context: Context) -> WorldbookEvaluationResult {
        let activeBooks = context.worldbooks.filter { $0.isEnabled }
        guard !activeBooks.isEmpty else { return .empty }

        let turn = runtimeStore.nextTurn(for: context.sessionID)
        let maxRecursionDepth = activeBooks.map { $0.settings.maxRecursionDepth }.max() ?? 0
        let maxInjectedEntries = activeBooks.map { $0.settings.maxInjectedEntries }.max() ?? 64
        let maxInjectedChars = activeBooks.map { $0.settings.maxInjectedCharacters }.max() ?? 6000

        var triggered: [WorldbookInjection] = []
        var triggeredIDs = Set<UUID>()
        var recursionBuffer: [String] = []

        for recursionLevel in 0...maxRecursionDepth {
            let entries = collectEntries(activeBooks)
            var newlyTriggeredContents: [String] = []

            for item in entries {
                let entry = item.entry

                if triggeredIDs.contains(entry.id) { continue }
                if !entry.isEnabled { continue }
                if recursionLevel > 0 && entry.preventRecursion { continue }
                if recursionLevel == 0 && entry.delayUntilRecursion { continue }

                var state = runtimeStore.state(for: context.sessionID, entryID: entry.id)

                let stickyActive = isStickyActive(entry: entry, state: state, currentTurn: turn)
                let inCooldown = isCooldownActive(entry: entry, state: state, currentTurn: turn)
                if inCooldown && !stickyActive {
                    continue
                }

                let scanDepth = max(1, entry.scanDepth ?? item.book.settings.scanDepth)
                let baseBuffer = buildScanBuffer(messages: context.messages, scanDepth: scanDepth, topicPrompt: context.topicPrompt, enhancedPrompt: context.enhancedPrompt)
                let effectiveBuffer: String
                if recursionLevel == 0 || entry.excludeRecursion {
                    effectiveBuffer = baseBuffer
                } else {
                    effectiveBuffer = baseBuffer + "\n" + recursionBuffer.joined(separator: "\n")
                }

                let matchResult = evaluateKeywordMatch(entry: entry, buffer: effectiveBuffer)
                let keywordMatched = stickyActive || entry.constant || matchResult.matched
                if !keywordMatched {
                    continue
                }

                if let delay = entry.delay, delay > 0, !stickyActive {
                    if let due = state.delayUntilTurn {
                        if turn < due {
                            runtimeStore.updateState(state, for: context.sessionID, entryID: entry.id)
                            continue
                        }
                    } else {
                        state.delayUntilTurn = turn + delay
                        runtimeStore.updateState(state, for: context.sessionID, entryID: entry.id)
                        continue
                    }
                }

                if entry.useProbability && !stickyActive {
                    let roll = randomSource() * 100
                    if roll > max(0, min(100, entry.probability)) {
                        continue
                    }
                }

                var updatedState = state
                updatedState.lastTriggeredTurn = turn
                updatedState.delayUntilTurn = nil
                if let sticky = entry.sticky, sticky > 0 {
                    updatedState.stickyUntilTurn = turn + sticky
                }
                if let cooldown = entry.cooldown, cooldown > 0 {
                    updatedState.cooldownUntilTurn = turn + cooldown
                }
                runtimeStore.updateState(updatedState, for: context.sessionID, entryID: entry.id)

                let injection = WorldbookInjection(
                    worldbookID: item.book.id,
                    worldbookName: item.book.name,
                    entryID: entry.id,
                    entryComment: entry.comment,
                    content: entry.content,
                    position: entry.position,
                    outletName: entry.outletName,
                    order: entry.order,
                    depth: entry.depth,
                    role: entry.role,
                    triggerScore: max(
                        0,
                        matchResult.score + (entry.constant ? 1 : 0) + (stickyActive ? 0.5 : 0)
                    )
                )
                triggered.append(injection)
                triggeredIDs.insert(entry.id)
                newlyTriggeredContents.append(entry.content)
            }

            if newlyTriggeredContents.isEmpty {
                break
            }
            recursionBuffer.append(contentsOf: newlyTriggeredContents)
        }

        let grouped = applyGroupRules(triggered, booksByID: Dictionary(uniqueKeysWithValues: activeBooks.map { ($0.id, $0) }))
        let budgeted = applyBudget(grouped, maxEntries: maxInjectedEntries, maxCharacters: maxInjectedChars)

        if !budgeted.isEmpty {
            logger.info("世界书激活完成: turn=\(turn), entries=\(budgeted.count)")
        }

        return buildResult(from: budgeted)
    }

    private func collectEntries(_ books: [Worldbook]) -> [(book: Worldbook, entry: WorldbookEntry)] {
        var result: [(book: Worldbook, entry: WorldbookEntry)] = []
        for book in books {
            for entry in book.entries {
                result.append((book: book, entry: entry))
            }
        }
        result.sort {
            if $0.entry.order == $1.entry.order {
                if $0.book.id == $1.book.id {
                    return $0.entry.id.uuidString < $1.entry.id.uuidString
                }
                return $0.book.id.uuidString < $1.book.id.uuidString
            }
            return $0.entry.order > $1.entry.order
        }
        return result
    }

    private func isStickyActive(entry: WorldbookEntry, state: WorldbookTimedEffectState, currentTurn: Int) -> Bool {
        guard entry.sticky != nil else { return false }
        guard let stickyUntil = state.stickyUntilTurn else { return false }
        return currentTurn <= stickyUntil
    }

    private func isCooldownActive(entry: WorldbookEntry, state: WorldbookTimedEffectState, currentTurn: Int) -> Bool {
        guard entry.cooldown != nil else { return false }
        guard let cooldownUntil = state.cooldownUntilTurn else { return false }
        return currentTurn <= cooldownUntil
    }

    private func buildScanBuffer(
        messages: [ChatMessage],
        scanDepth: Int,
        topicPrompt: String?,
        enhancedPrompt: String?
    ) -> String {
        let filtered = messages.filter { $0.role == .user || $0.role == .assistant || $0.role == .tool }
        let maxMessages = max(1, scanDepth * 2)
        let limited = Array(filtered.suffix(maxMessages))

        var lines: [String] = []
        if let topicPrompt, !topicPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("[Topic]\n\(topicPrompt)")
        }
        if let enhancedPrompt, !enhancedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("[Enhanced]\n\(enhancedPrompt)")
        }

        for message in limited {
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n")
    }

    private func evaluateKeywordMatch(entry: WorldbookEntry, buffer: String) -> (matched: Bool, score: Double) {
        let primaryKeys = entry.keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // 非 constant 条目，如果没有关键词则不触发，避免噪音注入。
        guard !primaryKeys.isEmpty else {
            return (false, 0)
        }

        let primaryMatches = primaryKeys.filter { key in
            keyword(key, matchesIn: buffer, entry: entry)
        }
        guard !primaryMatches.isEmpty else { return (false, 0) }
        var score = Double(primaryMatches.count)

        let secondary = entry.secondaryKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !secondary.isEmpty else { return (true, score) }

        let secondaryMatches = secondary.map { keyword($0, matchesIn: buffer, entry: entry) }
        let hitCount = secondaryMatches.filter { $0 }.count
        switch entry.selectiveLogic {
        case .andAny:
            let matched = secondaryMatches.contains(true)
            if matched {
                score += Double(hitCount)
            }
            return (matched, score)
        case .andAll:
            let matched = secondaryMatches.allSatisfy { $0 }
            if matched {
                score += Double(secondary.count)
            }
            return (matched, score)
        case .notAny:
            let matched = !secondaryMatches.contains(true)
            if matched {
                score += 1
            }
            return (matched, score)
        case .notAll:
            let matched = !secondaryMatches.allSatisfy { $0 }
            if matched {
                score += Double(max(1, secondary.count - hitCount))
            }
            return (matched, score)
        }
    }

    private func keyword(_ key: String, matchesIn buffer: String, entry: WorldbookEntry) -> Bool {
        if entry.useRegex {
            let options: NSRegularExpression.Options = entry.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: key, options: options) else {
                return false
            }
            let range = NSRange(buffer.startIndex..<buffer.endIndex, in: buffer)
            return regex.firstMatch(in: buffer, options: [], range: range) != nil
        }

        if entry.matchWholeWords {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = "\\b\(escaped)\\b"
            let options: NSRegularExpression.Options = entry.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return false
            }
            let range = NSRange(buffer.startIndex..<buffer.endIndex, in: buffer)
            return regex.firstMatch(in: buffer, options: [], range: range) != nil
        }

        if entry.caseSensitive {
            return buffer.contains(key)
        }
        return buffer.localizedCaseInsensitiveContains(key)
    }

    private func applyGroupRules(_ items: [WorldbookInjection], booksByID: [UUID: Worldbook]) -> [WorldbookInjection] {
        var direct: [WorldbookInjection] = []
        var grouped: [String: [WorldbookInjection]] = [:]

        for item in items {
            guard let book = booksByID[item.worldbookID],
                  let entry = book.entries.first(where: { $0.id == item.entryID }),
                  let group = entry.group?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !group.isEmpty else {
                direct.append(item)
                continue
            }
            grouped[group, default: []].append(item)
        }

        var selected = direct
        for (_, candidates) in grouped {
            let sorted = candidates.sorted {
                if $0.order == $1.order {
                    return $0.entryID.uuidString < $1.entryID.uuidString
                }
                return $0.order > $1.order
            }

            let overrideItems = sorted.filter { candidate in
                guard let book = booksByID[candidate.worldbookID],
                      let entry = book.entries.first(where: { $0.id == candidate.entryID }) else {
                    return false
                }
                return entry.groupOverride
            }
            if !overrideItems.isEmpty {
                selected.append(contentsOf: overrideItems)
                continue
            }

            let scored = sorted.map { candidate -> (WorldbookInjection, Double) in
                guard let book = booksByID[candidate.worldbookID],
                      let entry = book.entries.first(where: { $0.id == candidate.entryID }) else {
                    return (candidate, 0)
                }
                let weight = entry.groupWeight
                let triggerScore = entry.useGroupScoring ? candidate.triggerScore : 0
                let score = triggerScore * 100 + weight * 10 + Double(candidate.order) * 0.01
                return (candidate, score)
            }
            if let winner = scored.max(by: { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.entryID.uuidString > rhs.0.entryID.uuidString
                }
                return lhs.1 < rhs.1
            }) {
                selected.append(winner.0)
            }
        }

        return selected.sorted {
            if $0.order == $1.order {
                return $0.entryID.uuidString < $1.entryID.uuidString
            }
            return $0.order > $1.order
        }
    }

    private func applyBudget(_ items: [WorldbookInjection], maxEntries: Int, maxCharacters: Int) -> [WorldbookInjection] {
        var result: [WorldbookInjection] = []
        var totalChars = 0

        let sortedItems = items.sorted {
            if $0.order != $1.order {
                return $0.order > $1.order
            }
            if $0.triggerScore != $1.triggerScore {
                return $0.triggerScore > $1.triggerScore
            }
            return $0.entryID.uuidString < $1.entryID.uuidString
        }

        for item in sortedItems {
            if result.count >= maxEntries { break }
            let rendered = item.renderedContent
            let nextChars = totalChars + rendered.count
            if nextChars > maxCharacters {
                continue
            }
            result.append(item)
            totalChars = nextChars
        }

        return result
    }

    private func buildResult(from items: [WorldbookInjection]) -> WorldbookEvaluationResult {
        let before = items.filter { $0.position == .before }
        let after = items.filter { $0.position == .after }
        let anTop = items.filter { $0.position == .anTop }
        let anBottom = items.filter { $0.position == .anBottom }
        let emTop = items.filter { $0.position == .emTop }
        let emBottom = items.filter { $0.position == .emBottom }
        let outlet = items.filter { $0.position == .outlet }

        let depthMap = Dictionary(grouping: items.filter { $0.position == .atDepth }) { item in
            item.depth ?? 0
        }
        let depthInsertions = depthMap
            .map { depth, values in
                WorldbookDepthInsertion(
                    depth: depth,
                    items: values.sorted {
                        if $0.order == $1.order {
                            return $0.entryID.uuidString < $1.entryID.uuidString
                        }
                        return $0.order > $1.order
                    }
                )
            }
            .sorted { $0.depth > $1.depth }

        return WorldbookEvaluationResult(
            before: before,
            after: after,
            anTop: anTop,
            anBottom: anBottom,
            emTop: emTop,
            emBottom: emBottom,
            atDepth: depthInsertions,
            outlet: outlet,
            triggeredEntryIDs: items.map(\.entryID)
        )
    }
}
