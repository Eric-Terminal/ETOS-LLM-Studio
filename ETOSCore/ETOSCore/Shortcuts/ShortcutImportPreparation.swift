import Foundation

public struct ShortcutPreparedImport: Sendable {
    public let tools: [ShortcutToolDefinition]
    public let skippedCount: Int
    public let invalidCount: Int
    public let conflictNames: [String]
}

public struct ShortcutPreparationProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let currentName: String?
}

extension ShortcutToolManager {
    /// 解析、分享链接读取和描述生成只产生内存预览；取消不会向数据库写入部分清单。
    public func prepareImportInBackground(
        data: Data, progress: @escaping @Sendable (ShortcutPreparationProgress) async -> Void
    ) async throws -> ShortcutPreparedImport {
        let existing = tools
        let task = Task.detached(priority: .utility) {
            let payloads = try Self.decodeImportPayloads(from: data)
            let initial = Self.prepareImportCandidates(payloads, existing: existing, describe: self.makeGeneratedDescription(from:))
            var prepared: [ShortcutToolDefinition] = []
            for (index, candidate) in initial.tools.enumerated() {
                try Task.checkCancellation()
                await progress(ShortcutPreparationProgress(completed: index, total: initial.tools.count, currentName: candidate.name))
                var tool = await self.enrichToolWithDeepScanIfNeeded(candidate)
                try Task.checkCancellation()
                tool.generatedDescription = await ChatService.shared.generateShortcutToolDescription(
                    toolName: tool.name, metadata: tool.metadata, source: tool.source
                ) ?? self.makeGeneratedDescription(for: tool)
                try Task.checkCancellation()
                prepared.append(tool)
            }
            try Task.checkCancellation()
            await progress(ShortcutPreparationProgress(completed: prepared.count, total: prepared.count, currentName: nil))
            return ShortcutPreparedImport(tools: prepared, skippedCount: initial.skippedCount,
                                          invalidCount: initial.invalidCount, conflictNames: initial.conflictNames)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func prepareDescriptionInBackground(for tool: ShortcutToolDefinition) async throws -> String {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let generated = await ChatService.shared.generateShortcutToolDescription(toolName: tool.name, metadata: tool.metadata, source: tool.source)
            try Task.checkCancellation()
            return generated ?? self.makeGeneratedDescription(for: tool)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    nonisolated static func prepareImportCandidates(
        _ payloads: [ShortcutToolImportPayload], existing: [ShortcutToolDefinition],
        describe: (ShortcutToolImportPayload) -> String
    ) -> ShortcutPreparedImport {
        var keys = Set(existing.map { ShortcutToolNaming.normalizeExecutableName($0.name) })
        var tools: [ShortcutToolDefinition] = [], conflicts: [String] = []
        var invalid = 0
        for payload in payloads {
            let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { invalid += 1; continue }
            guard keys.insert(ShortcutToolNaming.normalizeExecutableName(name)).inserted else {
                conflicts.append(name); continue
            }
            tools.append(ShortcutToolDefinition(name: name, externalID: payload.externalID, metadata: payload.metadata,
                source: payload.source, runModeHint: payload.runModeHint ?? .direct, isEnabled: true,
                generatedDescription: describe(payload)))
        }
        return ShortcutPreparedImport(tools: tools, skippedCount: conflicts.count, invalidCount: invalid,
                                      conflictNames: Array(Set(conflicts)).sorted())
    }
}
