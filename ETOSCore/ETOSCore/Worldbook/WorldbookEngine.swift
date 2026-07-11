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

private struct WorldbookEntryRuntimeKey: Hashable {
    let worldbookID: UUID
    let entryID: UUID
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

    public func state(for sessionID: UUID, worldbookID: UUID, entryID: UUID) -> WorldbookTimedEffectState {
        queue.sync {
            let envelope = loadEnvelopeUnlocked()
            let sessionKey = sessionID.uuidString
            let entryKey = stateKey(worldbookID: worldbookID, entryID: entryID)
            let legacyEntryKey = entryID.uuidString
            return envelope.sessions[sessionKey]?.states[entryKey]
                ?? envelope.sessions[sessionKey]?.states[legacyEntryKey]
                ?? WorldbookTimedEffectState()
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

    public func updateState(_ state: WorldbookTimedEffectState, for sessionID: UUID, worldbookID: UUID, entryID: UUID) {
        queue.sync {
            var envelope = loadEnvelopeUnlocked()
            let sessionKey = sessionID.uuidString
            let entryKey = stateKey(worldbookID: worldbookID, entryID: entryID)
            var session = envelope.sessions[sessionKey] ?? SessionRuntimeState(turn: 0, states: [:])
            session.states[entryKey] = state
            envelope.sessions[sessionKey] = session
            saveEnvelopeUnlocked(envelope)
        }
    }

    private func stateKey(worldbookID: UUID, entryID: UUID) -> String {
        "\(worldbookID.uuidString)::\(entryID.uuidString)"
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
        public var personaDescription: String?
        public var characterDescription: String?
        public var characterPersonality: String?
        public var characterDepthPrompt: String?
        public var scenario: String?
        public var creatorNotes: String?
        public var vectorActivatedEntryIDs: Set<UUID>

        public init(
            sessionID: UUID,
            worldbooks: [Worldbook],
            messages: [ChatMessage],
            topicPrompt: String? = nil,
            enhancedPrompt: String? = nil,
            personaDescription: String? = nil,
            characterDescription: String? = nil,
            characterPersonality: String? = nil,
            characterDepthPrompt: String? = nil,
            scenario: String? = nil,
            creatorNotes: String? = nil,
            vectorActivatedEntryIDs: Set<UUID> = []
        ) {
            self.sessionID = sessionID
            self.worldbooks = worldbooks
            self.messages = messages
            self.topicPrompt = topicPrompt
            self.enhancedPrompt = enhancedPrompt
            self.personaDescription = personaDescription
            self.characterDescription = characterDescription
            self.characterPersonality = characterPersonality
            self.characterDepthPrompt = characterDepthPrompt
            self.scenario = scenario
            self.creatorNotes = creatorNotes
            self.vectorActivatedEntryIDs = vectorActivatedEntryIDs
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

    public func evaluateAsync(_ context: Context) async -> WorldbookEvaluationResult {
        let vectorEntries = context.worldbooks.flatMap(\.entries).filter { $0.isEnabled && $0.vectorized }
        guard !vectorEntries.isEmpty else { return evaluate(context) }
        let query = buildScanBuffer(
            messages: context.messages,
            scanDepth: context.worldbooks.map(\.settings.scanDepth).max() ?? 4,
            topicPrompt: context.topicPrompt,
            enhancedPrompt: context.enhancedPrompt
        )
        var resolved = context
        resolved.vectorActivatedEntryIDs = await WorldbookVectorMatcher.shared.activatedEntryIDs(
            entries: vectorEntries,
            query: query
        )
        return evaluate(resolved)
    }

    public func evaluate(_ context: Context) -> WorldbookEvaluationResult {
        let activeBooks = context.worldbooks
        guard !activeBooks.isEmpty else { return .empty }

        let turn = runtimeStore.nextTurn(for: context.sessionID)
        let maxRecursionDepth = activeBooks.map { $0.settings.maxRecursionDepth }.max() ?? 0
        let minimumActivations = activeBooks.map(\.minimumActivations).max() ?? 0
        let configuredMinimumDepth = activeBooks.map(\.minimumActivationDepthMax).max() ?? 0
        let minimumActivationDepthMax = configuredMinimumDepth > 0 ? configuredMinimumDepth : context.messages.count

        var triggered: [WorldbookInjection] = []
        var triggeredIDs = Set<WorldbookEntryRuntimeKey>()
        var recursionBuffer: [String] = []
        var previousStates: [WorldbookEntryRuntimeKey: WorldbookTimedEffectState] = [:]
        var activatedGroupNames = Set<String>()

        for recursionLevel in 0...maxRecursionDepth {
            let levelStartIndex = triggered.count
            let entries = collectEntries(activeBooks)
            var newlyTriggeredContents: [String] = []

            for item in entries {
                let entry = item.entry

                let entryKey = WorldbookEntryRuntimeKey(worldbookID: item.book.id, entryID: entry.id)
                if triggeredIDs.contains(entryKey) { continue }
                if !entry.isEnabled { continue }
                if entry.constant {
                    var updatedState = runtimeStore.state(for: context.sessionID, worldbookID: item.book.id, entryID: entry.id)
                    previousStates[entryKey] = updatedState
                    updatedState.lastTriggeredTurn = turn
                    updatedState.delayUntilTurn = nil
                    runtimeStore.updateState(updatedState, for: context.sessionID, worldbookID: item.book.id, entryID: entry.id)

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
                        triggerScore: 1
                    )
                    triggered.append(injection)
                    triggeredIDs.insert(entryKey)
                    newlyTriggeredContents.append(entry.content)
                    continue
                }
                if recursionLevel > 0 && entry.excludeRecursion { continue }
                if recursionLevel < entry.recursionDelayLevel { continue }

                var state = runtimeStore.state(for: context.sessionID, worldbookID: item.book.id, entryID: entry.id)

                let stickyActive = isStickyActive(entry: entry, state: state, currentTurn: turn)
                let inCooldown = isCooldownActive(entry: entry, state: state, currentTurn: turn)
                if inCooldown && !stickyActive {
                    continue
                }

                let scanDepth = max(1, entry.scanDepth ?? item.book.settings.scanDepth)
                let baseBuffer = buildScanBuffer(
                    messages: context.messages,
                    scanDepth: scanDepth,
                    topicPrompt: context.topicPrompt,
                    enhancedPrompt: context.enhancedPrompt,
                    entry: entry,
                    context: context
                )
                let effectiveBuffer: String
                if recursionLevel == 0 || entry.excludeRecursion {
                    effectiveBuffer = baseBuffer
                } else {
                    effectiveBuffer = baseBuffer + "\n" + recursionBuffer.joined(separator: "\n")
                }

                var matchResult = entry.vectorized
                    ? (matched: context.vectorActivatedEntryIDs.contains(entry.id), score: 1.0)
                    : evaluateKeywordMatch(entry: entry, buffer: effectiveBuffer)
                if !matchResult.matched,
                   minimumActivations > triggered.count,
                   minimumActivationDepthMax > scanDepth,
                   !entry.vectorized {
                    let expanded = buildScanBuffer(
                        messages: context.messages,
                        scanDepth: minimumActivationDepthMax,
                        topicPrompt: context.topicPrompt,
                        enhancedPrompt: context.enhancedPrompt,
                        entry: entry,
                        context: context
                    )
                    matchResult = evaluateKeywordMatch(entry: entry, buffer: expanded)
                }
                let keywordMatched = stickyActive || entry.constant || matchResult.matched
                if !keywordMatched {
                    continue
                }

                if let delay = entry.delay, delay > 0, !stickyActive {
                    if let due = state.delayUntilTurn {
                        if turn < due {
                            runtimeStore.updateState(state, for: context.sessionID, worldbookID: item.book.id, entryID: entry.id)
                            continue
                        }
                    } else {
                        state.delayUntilTurn = turn + delay
                        runtimeStore.updateState(state, for: context.sessionID, worldbookID: item.book.id, entryID: entry.id)
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
                previousStates[entryKey] = state
                updatedState.lastTriggeredTurn = turn
                updatedState.delayUntilTurn = nil
                if let sticky = entry.sticky, sticky > 0 {
                    updatedState.stickyUntilTurn = turn + sticky
                }
                if let cooldown = entry.cooldown, cooldown > 0 {
                    updatedState.cooldownUntilTurn = turn + cooldown
                }
                runtimeStore.updateState(updatedState, for: context.sessionID, worldbookID: item.book.id, entryID: entry.id)

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
                triggeredIDs.insert(entryKey)
                newlyTriggeredContents.append(entry.content)
            }

            let levelCandidates = Array(triggered[levelStartIndex...])
            let levelAccepted = filterInclusionGroups(
                levelCandidates,
                books: activeBooks,
                sessionID: context.sessionID,
                currentTurn: turn,
                lockedGroupNames: activatedGroupNames,
                statesBeforeEvaluation: previousStates
            )
            triggered.removeSubrange(levelStartIndex..<triggered.count)
            triggered.append(contentsOf: levelAccepted)
            let levelAcceptedKeys = Set(levelAccepted.map {
                WorldbookEntryRuntimeKey(worldbookID: $0.worldbookID, entryID: $0.entryID)
            })
            for candidate in levelCandidates {
                let key = WorldbookEntryRuntimeKey(worldbookID: candidate.worldbookID, entryID: candidate.entryID)
                guard !levelAcceptedKeys.contains(key), let state = previousStates.removeValue(forKey: key) else { continue }
                runtimeStore.updateState(
                    state,
                    for: context.sessionID,
                    worldbookID: key.worldbookID,
                    entryID: key.entryID
                )
            }
            let entryByKey = Dictionary(uniqueKeysWithValues: activeBooks.flatMap { book in
                book.entries.map { (WorldbookEntryRuntimeKey(worldbookID: book.id, entryID: $0.id), $0) }
            })
            newlyTriggeredContents = levelAccepted.compactMap { injection in
                let key = WorldbookEntryRuntimeKey(worldbookID: injection.worldbookID, entryID: injection.entryID)
                return entryByKey[key]?.preventRecursion == true ? nil : injection.content
            }
            activatedGroupNames.formUnion(groupNames(for: levelAccepted, books: activeBooks))

            if newlyTriggeredContents.isEmpty {
                break
            }
            recursionBuffer.append(contentsOf: newlyTriggeredContents)
        }

        let budgeted = applyBudgets(sortedInjections(triggered), books: activeBooks)
        let acceptedKeys = Set(budgeted.map {
            WorldbookEntryRuntimeKey(worldbookID: $0.worldbookID, entryID: $0.entryID)
        })
        for (key, state) in previousStates where !acceptedKeys.contains(key) {
            runtimeStore.updateState(
                state,
                for: context.sessionID,
                worldbookID: key.worldbookID,
                entryID: key.entryID
            )
        }

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
        enhancedPrompt: String?,
        entry: WorldbookEntry? = nil,
        context: Context? = nil
    ) -> String {
        let filtered = messages.filter { $0.role == .user || $0.role == .assistant || $0.role == .tool }
        let limited = Array(filtered.suffix(max(1, scanDepth)))

        var lines: [String] = []
        if let topicPrompt, !topicPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("[Topic]\n\(topicPrompt)")
        }
        if let enhancedPrompt, !enhancedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("[Enhanced]\n\(enhancedPrompt)")
        }
        if entry?.matchPersonaDescription == true,
           let value = context?.personaDescription,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("[Persona]\n\(value)")
        }
        if entry?.matchCharacterDescription == true,
           let value = context?.characterDescription,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("[Character Description]\n\(value)")
        }
        if entry?.matchCharacterPersonality == true,
           let value = context?.characterPersonality,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("[Character Personality]\n\(value)")
        }
        if entry?.matchCharacterDepthPrompt == true,
           let value = context?.characterDepthPrompt,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("[Character Depth Prompt]\n\(value)")
        }
        if entry?.matchScenario == true,
           let value = context?.scenario,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("[Scenario]\n\(value)")
        }
        if entry?.matchCreatorNotes == true,
           let value = context?.creatorNotes,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("[Creator Notes]\n\(value)")
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
        guard entry.secondaryKeysEnabled, !secondary.isEmpty else { return (true, score) }

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
            let parsed = parsedRegex(key, caseSensitive: entry.caseSensitive)
            guard let regex = try? NSRegularExpression(pattern: parsed.pattern, options: parsed.options) else {
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

    private func parsedRegex(
        _ raw: String,
        caseSensitive: Bool
    ) -> (pattern: String, options: NSRegularExpression.Options) {
        var options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard raw.hasPrefix("/"), let closing = raw.lastIndex(of: "/"), closing > raw.startIndex else {
            return (raw, options)
        }
        let pattern = String(raw[raw.index(after: raw.startIndex)..<closing])
        let flags = String(raw[raw.index(after: closing)...])
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("x") { options.insert(.allowCommentsAndWhitespace) }
        return (pattern, options)
    }

    private func filterInclusionGroups(
        _ injections: [WorldbookInjection],
        books: [Worldbook],
        sessionID: UUID,
        currentTurn: Int,
        lockedGroupNames: Set<String>,
        statesBeforeEvaluation: [WorldbookEntryRuntimeKey: WorldbookTimedEffectState]
    ) -> [WorldbookInjection] {
        let entries = Dictionary(uniqueKeysWithValues: books.flatMap { book in
            book.entries.map { (WorldbookEntryRuntimeKey(worldbookID: book.id, entryID: $0.id), $0) }
        })
        var kept = injections
        var groups: [String: [WorldbookInjection]] = [:]
        for injection in injections {
            let key = WorldbookEntryRuntimeKey(worldbookID: injection.worldbookID, entryID: injection.entryID)
            guard let group = entries[key]?.group else { continue }
            for name in group.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty {
                groups[name, default: []].append(injection)
            }
        }
        for name in groups.keys.sorted() {
            guard let original = groups[name] else { continue }
            let candidates = original.filter { candidate in
                kept.contains { $0.worldbookID == candidate.worldbookID && $0.entryID == candidate.entryID }
            }
            if lockedGroupNames.contains(name) {
                kept.removeAll { candidates.contains($0) }
                continue
            }
            guard candidates.count > 1 else { continue }

            let sticky = candidates.filter { candidate in
                let key = WorldbookEntryRuntimeKey(worldbookID: candidate.worldbookID, entryID: candidate.entryID)
                guard let entry = entries[key] else { return false }
                let state = statesBeforeEvaluation[key] ?? runtimeStore.state(
                    for: sessionID,
                    worldbookID: candidate.worldbookID,
                    entryID: candidate.entryID
                )
                return isStickyActive(entry: entry, state: state, currentTurn: currentTurn)
            }
            if !sticky.isEmpty {
                let stickyKeys = Set(sticky.map { WorldbookEntryRuntimeKey(worldbookID: $0.worldbookID, entryID: $0.entryID) })
                kept.removeAll { candidate in
                    candidates.contains(candidate) && !stickyKeys.contains(
                        WorldbookEntryRuntimeKey(worldbookID: candidate.worldbookID, entryID: candidate.entryID)
                    )
                }
                continue
            }

            let overrideCandidates = candidates.filter { candidate in
                let key = WorldbookEntryRuntimeKey(worldbookID: candidate.worldbookID, entryID: candidate.entryID)
                return entries[key]?.groupOverride == true
            }
            let scoringEnabled = candidates.contains { candidate in
                let key = WorldbookEntryRuntimeKey(worldbookID: candidate.worldbookID, entryID: candidate.entryID)
                return entries[key]?.useGroupScoring == true
            }
            let selectionPool: [WorldbookInjection]
            if !overrideCandidates.isEmpty {
                selectionPool = [overrideCandidates.sorted(by: injectionSort).first].compactMap { $0 }
            } else if scoringEnabled, let maxScore = candidates.map(\.triggerScore).max() {
                selectionPool = candidates.filter { $0.triggerScore == maxScore }
            } else {
                selectionPool = candidates
            }
            guard let winner = weightedWinner(selectionPool, entries: entries) else { continue }
            kept.removeAll { candidate in
                candidates.contains(candidate)
                    && !(candidate.worldbookID == winner.worldbookID && candidate.entryID == winner.entryID)
            }
        }
        return kept
    }

    private func groupNames(
        for injections: [WorldbookInjection],
        books: [Worldbook]
    ) -> Set<String> {
        let entries = Dictionary(uniqueKeysWithValues: books.flatMap { book in
            book.entries.map { (WorldbookEntryRuntimeKey(worldbookID: book.id, entryID: $0.id), $0) }
        })
        var names = Set<String>()
        for injection in injections {
            let key = WorldbookEntryRuntimeKey(worldbookID: injection.worldbookID, entryID: injection.entryID)
            guard let group = entries[key]?.group else { continue }
            for name in group.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty {
                names.insert(name)
            }
        }
        return names
    }

    private func weightedWinner(
        _ candidates: [WorldbookInjection],
        entries: [WorldbookEntryRuntimeKey: WorldbookEntry]
    ) -> WorldbookInjection? {
        guard !candidates.isEmpty else { return nil }
        let weights = candidates.map { candidate -> Double in
            let key = WorldbookEntryRuntimeKey(worldbookID: candidate.worldbookID, entryID: candidate.entryID)
            return max(0, entries[key]?.groupWeight ?? 1)
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return candidates.first }
        let roll = randomSource() * total
        var cursor = 0.0
        for (index, candidate) in candidates.enumerated() {
            cursor += weights[index]
            if roll <= cursor { return candidate }
        }
        return candidates.last
    }

    private func applyBudgets(
        _ injections: [WorldbookInjection],
        books: [Worldbook]
    ) -> [WorldbookInjection] {
        let settings = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0.settings) })
        let entries = Dictionary(uniqueKeysWithValues: books.flatMap { book in
            book.entries.map { (WorldbookEntryRuntimeKey(worldbookID: book.id, entryID: $0.id), $0) }
        })
        var accepted: [WorldbookInjection] = []
        var counts: [UUID: Int] = [:]
        var characters: [UUID: Int] = [:]
        for injection in injections {
            let key = WorldbookEntryRuntimeKey(worldbookID: injection.worldbookID, entryID: injection.entryID)
            if entries[key]?.ignoresBudget == true {
                accepted.append(injection)
                continue
            }
            guard let bookSettings = settings[injection.worldbookID] else {
                accepted.append(injection)
                continue
            }
            let nextCount = counts[injection.worldbookID, default: 0] + 1
            let nextCharacters = characters[injection.worldbookID, default: 0] + injection.content.count
            if bookSettings.maxInjectedEntries >= 0, nextCount > bookSettings.maxInjectedEntries { continue }
            if bookSettings.maxInjectedCharacters >= 0, nextCharacters > bookSettings.maxInjectedCharacters { continue }
            counts[injection.worldbookID] = nextCount
            characters[injection.worldbookID] = nextCharacters
            accepted.append(injection)
        }
        return accepted
    }

    private func injectionSort(_ lhs: WorldbookInjection, _ rhs: WorldbookInjection) -> Bool {
        if lhs.order != rhs.order { return lhs.order > rhs.order }
        if lhs.triggerScore != rhs.triggerScore { return lhs.triggerScore > rhs.triggerScore }
        return lhs.entryID.uuidString < rhs.entryID.uuidString
    }

    private func sortedInjections(_ items: [WorldbookInjection]) -> [WorldbookInjection] {
        items.sorted {
            if $0.order != $1.order {
                return $0.order > $1.order
            }
            if $0.triggerScore != $1.triggerScore {
                return $0.triggerScore > $1.triggerScore
            }
            if $0.worldbookID != $1.worldbookID {
                return $0.worldbookID.uuidString < $1.worldbookID.uuidString
            }
            return $0.entryID.uuidString < $1.entryID.uuidString
        }
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
