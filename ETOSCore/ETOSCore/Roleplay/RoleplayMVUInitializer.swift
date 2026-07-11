// ============================================================================
// RoleplayMVUInitializer.swift
// ============================================================================
// ETOS LLM Studio
//
// 从世界书 [initvar] 与开场白 <initvar> 构建会话级原生 MVU 初始状态。
// ============================================================================

import Foundation

struct RoleplayMVUInitializationResult: Hashable, Sendable {
    var data: RoleplayMVUData
    var loadedSourceCount: Int
    var failureReasons: [String]
}

enum RoleplayMVUInitializer {
    static func initialize(
        greeting: String,
        worldbooks: [Worldbook],
        primaryWorldbookID: UUID?,
        existingVariables: [String: JSONValue],
        macroContext: RoleplayMacroContext
    ) -> RoleplayMVUInitializationResult {
        let enabledWorldbooks = worldbooks.filter(\.isEnabled)
        let greetingPayloads = taggedContents(named: "initvar", in: greeting)
        var failures: [String] = []
        var loadedSourceCount = 0
        var initializedLorebooks: [String: [JSONValue]] = [:]
        var statData: [String: JSONValue] = [:]

        if greetingPayloads.isEmpty {
            for worldbook in enabledWorldbooks {
                let loaded = loadInitvarEntries(
                    from: worldbook,
                    macroContext: macroContext,
                    failures: &failures
                )
                RoleplayMVUData.merge(loaded.variables, into: &statData)
                initializedLorebooks[worldbook.name] = loaded.entryIdentifiers
                loadedSourceCount += loaded.loadedCount
            }
        } else {
            for payload in greetingPayloads {
                let failureCount = failures.count
                mergePayload(
                    payload,
                    sourceName: "开场白 <initvar>",
                    macroContext: macroContext,
                    into: &statData,
                    failures: &failures
                )
                if failures.count == failureCount { loadedSourceCount += 1 }
            }
            for worldbook in enabledWorldbooks {
                if worldbook.id == primaryWorldbookID {
                    initializedLorebooks[worldbook.name] = []
                    continue
                }
                let loaded = loadInitvarEntries(
                    from: worldbook,
                    macroContext: macroContext,
                    failures: &failures
                )
                var additionalVariables = loaded.variables
                RoleplayMVUData.merge(statData, into: &additionalVariables)
                statData = additionalVariables
                initializedLorebooks[worldbook.name] = loaded.entryIdentifiers
                loadedSourceCount += loaded.loadedCount
            }
        }

        let existing = RoleplayMVUData(variables: existingVariables)
        RoleplayMVUData.merge(existing.statData, into: &statData)
        initializedLorebooks.merge(existing.initializedLorebooks) { loaded, stored in
            stored.isEmpty ? loaded : stored
        }
        var data = RoleplayMVUData(
            initializedLorebooks: initializedLorebooks,
            statData: statData,
            displayData: statData,
            extra: existing.extra
        )
        data.regenerateSchema()
        return RoleplayMVUInitializationResult(
            data: data,
            loadedSourceCount: loadedSourceCount,
            failureReasons: failures
        )
    }

    static func taggedContents(named tag: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(NSRegularExpression.escapedPattern(for: tag))\\b[^>]*>([\\s\\S]*?)</\(NSRegularExpression.escapedPattern(for: tag))>",
            options: [.caseInsensitive]
        ) else { return [] }
        let value = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: value.length)).compactMap { match in
            guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
            return unwrapCodeFence(value.substring(with: match.range(at: 1)))
        }
    }

    private struct LoadedWorldbook {
        var variables: [String: JSONValue]
        var entryIdentifiers: [JSONValue]
        var loadedCount: Int
    }

    private static func loadInitvarEntries(
        from worldbook: Worldbook,
        macroContext: RoleplayMacroContext,
        failures: inout [String]
    ) -> LoadedWorldbook {
        var variables: [String: JSONValue] = [:]
        var identifiers: [JSONValue] = []
        var loadedCount = 0
        for entry in worldbook.entries where entry.comment.range(
            of: #"\[initvar\]"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            let payload = taggedContents(named: "initvar", in: entry.content).first
                ?? unwrapCodeFence(entry.content)
            let failureCount = failures.count
            mergePayload(
                payload,
                sourceName: "世界书“\(worldbook.name)”条目“\(entry.comment)”",
                macroContext: macroContext,
                into: &variables,
                failures: &failures
            )
            guard failures.count == failureCount else { continue }
            identifiers.append(entry.uid.map(JSONValue.int) ?? .string(entry.id.uuidString))
            loadedCount += 1
        }
        return LoadedWorldbook(
            variables: variables,
            entryIdentifiers: identifiers,
            loadedCount: loadedCount
        )
    }

    private static func mergePayload(
        _ payload: String,
        sourceName: String,
        macroContext: RoleplayMacroContext,
        into variables: inout [String: JSONValue],
        failures: inout [String]
    ) {
        let resolved = RoleplayMacroResolver.resolve(payload, context: macroContext)
        do {
            guard case .dictionary(let parsed) = try RoleplayYAMLParser.parse(resolved) else {
                failures.append("\(sourceName)的根节点不是对象。")
                return
            }
            RoleplayMVUData.merge(parsed, into: &variables)
        } catch {
            failures.append("\(sourceName)解析失败：\(error.localizedDescription)")
        }
    }

    private static func unwrapCodeFence(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(
            pattern: #"^```[^\n]*\n([\s\S]*?)\n```$"#,
            options: [.caseInsensitive]
        ) else { return trimmed }
        let value = trimmed as NSString
        guard let match = regex.firstMatch(
            in: trimmed,
            range: NSRange(location: 0, length: value.length)
        ), match.numberOfRanges > 1 else { return trimmed }
        return value.substring(with: match.range(at: 1))
    }
}
