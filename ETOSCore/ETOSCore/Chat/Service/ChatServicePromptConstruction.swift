// ============================================================================
// ChatServicePromptConstruction.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的系统提示词拼装、世界书注入与周期性时间路标构造。
// ============================================================================

import Foundation

extension ChatService {
    func buildFinalSystemPrompt(
        global: String?,
        topic: String?,
        memories: [MemoryItem],
        recentConversationSummaries: [ConversationSessionSummary],
        conversationProfile: ConversationUserProfile?,
        includeSystemTime: Bool,
        worldbookBefore: [WorldbookInjection] = [],
        worldbookAfter: [WorldbookInjection] = [],
        worldbookANTop: [WorldbookInjection] = [],
        worldbookANBottom: [WorldbookInjection] = [],
        worldbookOutlet: [WorldbookInjection] = []
    ) -> String {
        var parts: [String] = []

        if !worldbookBefore.isEmpty {
            parts.append(makeWorldbookPromptBlock(tag: "worldbook_before", entries: worldbookBefore))
        }
        if !worldbookAfter.isEmpty {
            parts.append(makeWorldbookPromptBlock(tag: "worldbook_after", entries: worldbookAfter))
        }
        if !worldbookANTop.isEmpty {
            parts.append(makeWorldbookPromptBlock(tag: "worldbook_an_top", entries: worldbookANTop))
        }
        if !worldbookANBottom.isEmpty {
            parts.append(makeWorldbookPromptBlock(tag: "worldbook_an_bottom", entries: worldbookANBottom))
        }
        if !worldbookOutlet.isEmpty {
            parts.append(contentsOf: makeWorldbookOutletBlocks(entries: worldbookOutlet))
        }

        if let global, !global.isEmpty {
            parts.append("<system_prompt>\n\(global)\n</system_prompt>")
        }

        if let topic, !topic.isEmpty {
            parts.append("<topic_prompt>\n\(topic)\n</topic_prompt>")
        }

        if includeSystemTime {
            parts.append(makeSystemTimePromptBlock())
        }

        if !memories.isEmpty {
            let sendUpdateTime = shouldSendMemoryUpdateTime()
            let memoryStrings = memories.map { memory in
                var metadata = ["type=\(memory.kind.promptLabel)"]
                metadata.append("importance=\(String(format: "%.2f", memory.importance))")
                metadata.append("confidence=\(String(format: "%.2f", memory.confidence))")
                if !memory.entities.isEmpty {
                    metadata.append("entities=\(memory.entities.joined(separator: ", "))")
                }
                if let validFrom = memory.validFrom {
                    metadata.append("valid_from=\(validFrom.formatted(date: .abbreviated, time: .shortened))")
                }
                if let validUntil = memory.validUntil {
                    metadata.append("valid_until=\(validUntil.formatted(date: .abbreviated, time: .shortened))")
                }
                if sendUpdateTime {
                    let displayDate = (memory.updatedAt ?? memory.createdAt).formatted(date: .abbreviated, time: .shortened)
                    metadata.append("updated_at=\(displayDate)")
                }
                return "- [\(metadata.joined(separator: "; "))] \(memory.content)"
            }
            let memoriesContent = memoryStrings.joined(separator: "\n")
            parts.append(BuiltInPromptStore.render(
                .longTermMemory,
                variables: ["memory": memoriesContent]
            ))
        }

        if !recentConversationSummaries.isEmpty {
            let conversationLines = recentConversationSummaries.map { item in
                "- (\(item.updatedAt.formatted(date: .abbreviated, time: .shortened))) [\(item.sessionName)]: \(item.summary)"
            }
            let conversationContent = conversationLines.joined(separator: "\n")
            parts.append(BuiltInPromptStore.render(
                .recentConversationMemory,
                variables: ["memory": conversationContent]
            ))
        }

        if let conversationProfile,
           !conversationProfile.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let profileUpdatedAt = conversationProfile.updatedAt.formatted(date: .abbreviated, time: .shortened)
            parts.append(BuiltInPromptStore.render(
                .userProfileMemory,
                variables: [
                    "memory": conversationProfile.promptRepresentation,
                    "updated_at": profileUpdatedAt
                ]
            ))
        }

        return parts.joined(separator: "\n\n")
    }

    func makeEnhancedPromptSystemMessage(_ enhancedPrompt: String?) -> ChatMessage? {
        guard let enhancedPrompt else { return nil }
        let trimmed = enhancedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let content = BuiltInPromptStore.render(
            .enhancedPrompt,
            variables: ["instruction": trimmed]
        )
        return ChatMessage(role: .system, content: content)
    }

    func makeSystemTimeSystemMessage() -> ChatMessage {
        ChatMessage(role: .system, content: makeSystemTimePromptBlock())
    }

    func makeSystemTimePromptBlock() -> String {
        BuiltInPromptStore.render(
            .systemTime,
            variables: ["time": SystemTimeContextFormatter.description()]
        )
    }

    func makeWorldbookPromptBlock(
        tag: String,
        entries: [WorldbookInjection],
        attributes: [String: String] = [:]
    ) -> String {
        let lines = entries.map { injection in
            let comment = injection.entryComment.trimmingCharacters(in: .whitespacesAndNewlines)
            if comment.isEmpty {
                return "- [\(injection.worldbookName)] \(injection.content)"
            }
            return "- [\(injection.worldbookName) / \(comment)] \(injection.content)"
        }.joined(separator: "\n")
        let attrs: String
        if attributes.isEmpty {
            attrs = ""
        } else {
            let rendered = attributes
                .sorted(by: { $0.key < $1.key })
                .map { key, value in
                    "\(key)=\"\(xmlEscapedAttribute(value))\""
                }
                .joined(separator: " ")
            attrs = rendered.isEmpty ? "" : " \(rendered)"
        }
        return "<\(tag)\(attrs)>\n\(lines)\n</\(tag)>"
    }

    func makeWorldbookOutletBlocks(entries: [WorldbookInjection]) -> [String] {
        let grouped = Dictionary(grouping: entries) { injection -> String in
            let trimmed = injection.outletName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "default" : trimmed
        }
        return grouped.keys.sorted().compactMap { outletName in
            guard let outletEntries = grouped[outletName], !outletEntries.isEmpty else { return nil }
            return makeWorldbookPromptBlock(
                tag: "worldbook_outlet",
                entries: outletEntries,
                attributes: ["name": outletName]
            )
        }
    }

    func xmlEscapedAttribute(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func makeWorldbookRoleMessages(_ entries: [WorldbookInjection], tag: String) -> [ChatMessage] {
        guard !entries.isEmpty else { return [] }
        let grouped = Dictionary(grouping: entries, by: \.role)
        var messages: [ChatMessage] = []

        if let systemEntries = grouped[.system], !systemEntries.isEmpty {
            let content = makeWorldbookPromptBlock(tag: tag, entries: systemEntries)
            messages.append(ChatMessage(role: .system, content: content))
        }

        if let assistantEntries = grouped[.assistant], !assistantEntries.isEmpty {
            let content = makeWorldbookPromptBlock(tag: tag, entries: assistantEntries)
            messages.append(ChatMessage(role: .assistant, content: content))
        }

        if let userEntries = grouped[.user], !userEntries.isEmpty {
            let block = makeWorldbookPromptBlock(tag: tag, entries: userEntries)
            let wrapped = "<system>\n\(block)\n</system>"
            messages.append(ChatMessage(role: .user, content: wrapped))
        }

        return messages
    }

    func injectAtDepthMessages(_ depthEntries: [WorldbookDepthInsertion], into chatHistory: [ChatMessage]) -> [ChatMessage] {
        guard !depthEntries.isEmpty else { return chatHistory }
        var updated = chatHistory
        for insertion in depthEntries.sorted(by: { $0.depth > $1.depth }) {
            let tag = "worldbook_at_depth_\(max(0, insertion.depth))"
            let messages = makeWorldbookRoleMessages(insertion.items, tag: tag)
            guard !messages.isEmpty else { continue }
            let resolvedDepth = max(0, insertion.depth)
            let targetIndex = max(0, updated.count - resolvedDepth)
            let safeInsertIndex = findSafeInsertIndex(targetIndex, in: updated)
            if safeInsertIndex >= updated.count {
                updated.append(contentsOf: messages)
            } else {
                updated.insert(contentsOf: messages, at: safeInsertIndex)
            }
        }
        return updated
    }

    func injectPeriodicTimeLandmarkIfNeeded(
        into chatHistory: [ChatMessage],
        sessionID: UUID,
        now: Date,
        intervalMinutes: Int
    ) -> [ChatMessage] {
        guard !chatHistory.isEmpty else { return chatHistory }

        let safeIntervalMinutes = max(1, intervalMinutes)
        let interval = TimeInterval(safeIntervalMinutes * 60)
        if let lastInjectedAt = periodicTimeLandmarkLastInjectedAtBySessionID[sessionID],
           now.timeIntervalSince(lastInjectedAt) < interval {
            return chatHistory
        }

        let cutoff = now.addingTimeInterval(-interval)
        var anchorIndex: Int?
        var anchorTime: Date?

        for (index, message) in chatHistory.enumerated() {
            guard let timestamp = messageTimelineTimestamp(for: message), timestamp <= cutoff else {
                continue
            }
            if let bestTime = anchorTime {
                if timestamp >= bestTime {
                    anchorTime = timestamp
                    anchorIndex = index
                }
            } else {
                anchorTime = timestamp
                anchorIndex = index
            }
        }

        guard let resolvedIndex = anchorIndex, let resolvedAnchorTime = anchorTime else {
            return chatHistory
        }

        var updated = chatHistory
        updated.insert(
            makePeriodicTimeLandmarkMessage(anchorTime: resolvedAnchorTime),
            at: resolvedIndex
        )
        periodicTimeLandmarkLastInjectedAtBySessionID[sessionID] = now
        return updated
    }

    func messageTimelineTimestamp(for message: ChatMessage) -> Date? {
        if let requestedAt = message.requestedAt {
            return requestedAt
        }
        if let requestStartedAt = message.responseMetrics?.requestStartedAt {
            return requestStartedAt
        }
        return message.responseMetrics?.responseCompletedAt
    }

    func makePeriodicTimeLandmarkMessage(anchorTime: Date) -> ChatMessage {
        let content = BuiltInPromptStore.render(
            .systemTime,
            variables: ["time": SystemTimeContextFormatter.description(at: anchorTime)]
        )
        return ChatMessage(role: .system, content: content)
    }

    func findSafeInsertIndex(_ preferredIndex: Int, in messages: [ChatMessage]) -> Int {
        guard !messages.isEmpty else { return max(0, preferredIndex) }
        var index = max(0, min(preferredIndex, messages.count))
        guard index > 0, index < messages.count else { return index }

        var cursor = 0
        while cursor < messages.count {
            let message = messages[cursor]
            let hasToolCalls = message.role == .assistant && !(message.toolCalls?.isEmpty ?? true)
            guard hasToolCalls else {
                cursor += 1
                continue
            }

            let rangeStart = cursor + 1
            var rangeEnd = rangeStart
            while rangeEnd < messages.count, messages[rangeEnd].role == .tool {
                rangeEnd += 1
            }

            if rangeStart < rangeEnd && index >= rangeStart && index < rangeEnd {
                index = cursor
                break
            }
            cursor = max(cursor + 1, rangeEnd)
        }

        return index
    }
}
