// ============================================================================
// ShortcutToolManager.swift
// ============================================================================
// 快捷指令工具管理器：导入、工具暴露、执行与回调
// ============================================================================

import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

@MainActor
public final class ShortcutToolManager: ObservableObject {
    public static let shared = ShortcutToolManager()

    public nonisolated static var toolNamePrefix: String { "shortcut://" }
    public nonisolated static var toolAliasPrefix: String { ShortcutToolNaming.toolAliasPrefix }

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ShortcutToolManager")
    private let executionTimeoutSeconds: UInt64 = 45
    private let bridgeShortcutUserDefaultsKey = "shortcut.bridgeShortcutName"

    @Published public private(set) var tools: [ShortcutToolDefinition] = []
    @Published public private(set) var lastImportSummary: ShortcutImportSummary?
    @Published public private(set) var lastExecutionResult: ShortcutToolExecutionResult?
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var isImporting: Bool = false
    @Published public private(set) var importProgressCompleted: Int = 0
    @Published public private(set) var importProgressTotal: Int = 0
    @Published public private(set) var importCurrentItemName: String?

    private var routedTools: [String: ShortcutToolDefinition] = [:]
    private var pendingExecutions: [String: PendingExecution] = [:]
    private var importCancellationRequested = false

    private struct PendingExecution {
        let requestID: String
        let toolName: String
        let transport: ShortcutExecutionTransport
        let startedAt: Date
        let continuation: CheckedContinuation<ShortcutToolExecutionResult, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private init() {
        reloadFromDisk()
    }

    public nonisolated static func isShortcutToolName(_ name: String) -> Bool {
        name.hasPrefix(toolAliasPrefix) || name.hasPrefix(toolNamePrefix)
    }

    public func isRegisteredToolName(_ name: String) -> Bool {
        routedTools[name] != nil
    }

    public func reloadFromDisk() {
        let loaded = ShortcutToolStore.loadTools()
        tools = loaded.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        rebuildRouting()
    }

    public var bridgeShortcutName: String {
        get {
            let value = UserDefaults.standard.string(forKey: bridgeShortcutUserDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false ? value! : "ETOS Shortcut Bridge")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: bridgeShortcutUserDefaultsKey)
        }
    }

    // MARK: - CRUD

    public func setToolEnabled(id: UUID, isEnabled: Bool) {
        guard let index = tools.firstIndex(where: { $0.id == id }) else { return }
        tools[index].isEnabled = isEnabled
        tools[index].updatedAt = Date()
        persistCurrentTools()
    }

    public func setRunModeHint(id: UUID, runModeHint: ShortcutRunModeHint) {
        guard let index = tools.firstIndex(where: { $0.id == id }) else { return }
        tools[index].runModeHint = runModeHint
        tools[index].updatedAt = Date()
        persistCurrentTools()
    }

    public func updateUserDescription(id: UUID, description: String) {
        guard let index = tools.firstIndex(where: { $0.id == id }) else { return }
        tools[index].userDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        tools[index].updatedAt = Date()
        persistCurrentTools()
    }

    public func regenerateDescription(for id: UUID) {
        guard let index = tools.firstIndex(where: { $0.id == id }) else { return }
        tools[index].generatedDescription = makeGeneratedDescription(for: tools[index])
        tools[index].updatedAt = Date()
        persistCurrentTools()
    }

    public func regenerateDescriptionWithLLM(for id: UUID) async {
        guard let index = tools.firstIndex(where: { $0.id == id }) else { return }
        let tool = tools[index]
        let generated = await ChatService.shared.generateShortcutToolDescription(
            toolName: tool.name,
            metadata: tool.metadata,
            source: tool.source
        ) ?? makeGeneratedDescription(for: tool)
        tools[index].generatedDescription = generated
        tools[index].updatedAt = Date()
        persistCurrentTools()
    }

    public func deleteTool(id: UUID) {
        tools.removeAll { $0.id == id }
        persistCurrentTools()
    }

    public func cancelOngoingImport() {
        guard isImporting else { return }
        importCancellationRequested = true
    }

    // MARK: - Import

    @discardableResult
    public func importFromClipboard(triggerURL: URL?) async -> ShortcutImportSummary {
        if isImporting {
            let summary = ShortcutImportSummary(importedCount: 0, skippedCount: 0, conflictNames: [], invalidCount: 0)
            lastImportSummary = summary
            lastErrorMessage = NSLocalizedString("当前已有导入任务正在进行。", comment: "")
            return summary
        }

        beginImportProgress()
        defer { endImportProgress() }

        do {
            let source = queryItem(named: "source", in: triggerURL)?.lowercased() ?? "clipboard"
            guard source == "clipboard" else {
                throw ShortcutToolError.unsupportedImportSource
            }

            guard let text = clipboardText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ShortcutToolError.clipboardEmpty
            }

            guard let data = text.data(using: .utf8) else {
                throw ShortcutToolError.invalidManifest
            }

            let importedPayloads = try decodeImportPayloads(from: data)
            importProgressTotal = max(importedPayloads.count, 1)
            try ensureImportNotCancelled()

            var nextTools = tools
            var imported = 0
            var skipped = 0
            var invalid = 0
            var conflicts: [String] = []
            var importedIDs: [UUID] = []

            var existingKeys = Set(nextTools.map { ShortcutToolNaming.normalizeExecutableName($0.name) })
            var batchKeys = Set<String>()

            for payload in importedPayloads {
                try ensureImportNotCancelled()
                let trimmedName = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
                updateImportProgress(currentName: trimmedName, increment: 0)
                guard !trimmedName.isEmpty else {
                    invalid += 1
                    updateImportProgress(currentName: nil, increment: 1)
                    continue
                }

                let key = ShortcutToolNaming.normalizeExecutableName(trimmedName)
                if existingKeys.contains(key) || batchKeys.contains(key) {
                    skipped += 1
                    conflicts.append(trimmedName)
                    updateImportProgress(currentName: nil, increment: 1)
                    continue
                }

                batchKeys.insert(key)
                existingKeys.insert(key)

                let now = Date()
                let tool = ShortcutToolDefinition(
                    name: trimmedName,
                    externalID: payload.externalID,
                    metadata: payload.metadata,
                    source: payload.source,
                    runModeHint: payload.runModeHint ?? .direct,
                    isEnabled: false,
                    userDescription: nil,
                    generatedDescription: makeGeneratedDescription(from: payload),
                    createdAt: now,
                    updatedAt: now,
                    lastImportedAt: now
                )
                nextTools.append(tool)
                importedIDs.append(tool.id)
                imported += 1
                updateImportProgress(currentName: nil, increment: 1)
            }

            if !importedIDs.isEmpty {
                let importedIDSet = Set(importedIDs)
                importProgressTotal = importedPayloads.count + importedIDSet.count
                for index in nextTools.indices where importedIDSet.contains(nextTools[index].id) {
                    try ensureImportNotCancelled()
                    var tool = nextTools[index]
                    updateImportProgress(currentName: tool.name, increment: 0)
                    tool = await enrichToolWithDeepScanIfNeeded(tool)
                    try ensureImportNotCancelled()
                    let generated = await ChatService.shared.generateShortcutToolDescription(
                        toolName: tool.name,
                        metadata: tool.metadata,
                        source: tool.source
                    ) ?? tool.generatedDescription
                    tool.generatedDescription = generated
                    tool.updatedAt = Date()
                    nextTools[index] = tool
                    updateImportProgress(currentName: nil, increment: 1)
                }
            }

            nextTools.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            tools = nextTools
            persistCurrentTools()

            let summary = ShortcutImportSummary(
                importedCount: imported,
                skippedCount: skipped,
                conflictNames: Array(Set(conflicts)).sorted(),
                invalidCount: invalid
            )
            lastImportSummary = summary
            lastErrorMessage = nil

            await notifyImportCallback(summary: summary, triggerURL: triggerURL, success: true, errorMessage: nil)
            return summary
        } catch is CancellationError {
            let summary = ShortcutImportSummary(importedCount: 0, skippedCount: 0, conflictNames: [], invalidCount: 0)
            lastImportSummary = summary
            lastErrorMessage = NSLocalizedString("导入已取消。", comment: "")
            await notifyImportCallback(summary: summary, triggerURL: triggerURL, success: false, errorMessage: lastErrorMessage)
            return summary
        } catch {
            let summary = ShortcutImportSummary(importedCount: 0, skippedCount: 0, conflictNames: [], invalidCount: 0)
            lastImportSummary = summary
            lastErrorMessage = error.localizedDescription
            await notifyImportCallback(summary: summary, triggerURL: triggerURL, success: false, errorMessage: error.localizedDescription)
            return summary
        }
    }

    // MARK: - Chat Integration

    public func chatToolsForLLM() -> [InternalToolDefinition] {
        tools
            .filter { $0.isEnabled }
            .map { tool in
                let alias = ShortcutToolNaming.alias(for: tool)
                let description = "[快捷指令] \(tool.effectiveDescription)"
                let parameters: JSONValue
                if let schema = tool.metadata["inputSchema"] {
                    parameters = schema
                } else {
                    parameters = .dictionary([
                        "type": .string("object"),
                        "additionalProperties": .bool(true)
                    ])
                }
                return InternalToolDefinition(name: alias, description: description, parameters: parameters, isBlocking: true)
            }
    }

    public func displayLabel(for toolName: String) -> String? {
        guard let tool = routedTools[toolName] else { return nil }
        return "[快捷指令] \(tool.displayName)"
    }

    public func executeToolFromChat(toolName: String, argumentsJSON: String) async throws -> String {
        guard let tool = routedTools[toolName] else {
            throw ShortcutToolError.unknownTool
        }
        let result = await executeWithFallback(tool: tool, argumentsJSON: argumentsJSON, allowRelayOnWatch: true)
        lastExecutionResult = result

        guard result.success else {
            throw ShortcutToolError.executionFailed(result.errorMessage ?? NSLocalizedString("快捷指令执行失败。", comment: ""))
        }
        return formatResultText(result.result)
    }

    public func executeRelayRequest(_ request: ShortcutToolExecutionRequest) async -> ShortcutToolExecutionResult {
        guard let tool = routedTools[request.toolName] else {
            return ShortcutToolExecutionResult(
                requestID: request.requestID,
                toolName: request.toolName,
                success: false,
                result: nil,
                errorMessage: ShortcutToolError.unknownTool.localizedDescription,
                transport: .relay,
                startedAt: request.requestedAt,
                finishedAt: Date()
            )
        }

        let result = await executeWithFallback(tool: tool, argumentsJSON: request.argumentsJSON, allowRelayOnWatch: false)
        var relayResult = result
        relayResult.transport = .relay
        lastExecutionResult = relayResult
        return relayResult
    }

    // MARK: - Callback

    @discardableResult
    public func handleCallbackURL(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "shortcuts" else { return false }
        guard url.path.lowercased() == "/callback" else { return false }

        let requestID = queryItem(named: "request_id", in: url)
            ?? queryItem(named: "requestId", in: url)
        guard let requestID else {
            return false
        }

        guard let pending = pendingExecutions[requestID] else {
            return true
        }

        let status = (queryItem(named: "status", in: url) ?? "success").lowercased()
        let resultText = queryItem(named: "result", in: url)
        let errorMessage = queryItem(named: "errorMessage", in: url)
        let transportRaw = queryItem(named: "transport", in: url)
        let transport = ShortcutExecutionTransport(rawValue: transportRaw ?? "") ?? pending.transport

        let success = status != "error" && (errorMessage == nil)
        let result = ShortcutToolExecutionResult(
            requestID: requestID,
            toolName: pending.toolName,
            success: success,
            result: success ? resultText : nil,
            errorMessage: success ? nil : (errorMessage ?? NSLocalizedString("快捷指令执行失败。", comment: "")),
            transport: transport,
            startedAt: pending.startedAt,
            finishedAt: Date()
        )

        resolvePending(requestID: requestID, result: result)
        lastExecutionResult = result
        return true
    }

    // MARK: - Internal Execution

    private func executeWithFallback(
        tool: ShortcutToolDefinition,
        argumentsJSON: String,
        allowRelayOnWatch: Bool
    ) async -> ShortcutToolExecutionResult {
        let order: [ShortcutExecutionTransport] = {
            switch tool.runModeHint {
            case .bridge:
                return [.bridge, .direct]
            case .direct:
                return [.direct, .bridge]
            }
        }()

        var lastFailure: ShortcutToolExecutionResult?

        for transport in order {
            let localResult = await executeLocally(tool: tool, argumentsJSON: argumentsJSON, transport: transport)
            if localResult.success {
                return localResult
            }
            lastFailure = localResult

            #if os(watchOS)
            if allowRelayOnWatch {
                let relayRequest = ShortcutToolExecutionRequest(
                    toolName: ShortcutToolNaming.alias(for: tool),
                    argumentsJSON: argumentsJSON,
                    preferredTransport: transport
                )
                do {
                    let relayResult = try await ShortcutExecutionRelay.shared.executeViaCompanion(request: relayRequest)
                    if relayResult.success {
                        return relayResult
                    }
                    lastFailure = relayResult
                } catch {
                    lastFailure = ShortcutToolExecutionResult(
                        requestID: relayRequest.requestID,
                        toolName: tool.name,
                        success: false,
                        result: nil,
                        errorMessage: error.localizedDescription,
                        transport: .relay,
                        startedAt: relayRequest.requestedAt,
                        finishedAt: Date()
                    )
                }
            }
            #endif
        }

        return lastFailure ?? ShortcutToolExecutionResult(
            requestID: UUID().uuidString,
            toolName: tool.name,
            success: false,
            result: nil,
            errorMessage: NSLocalizedString("快捷指令执行失败。", comment: ""),
            transport: .direct,
            startedAt: Date(),
            finishedAt: Date()
        )
    }

    private func executeLocally(
        tool: ShortcutToolDefinition,
        argumentsJSON: String,
        transport: ShortcutExecutionTransport
    ) async -> ShortcutToolExecutionResult {
        let requestID = UUID().uuidString
        let targetShortcutName: String
        let payloadText: String

        switch transport {
        case .direct:
            targetShortcutName = tool.name
            payloadText = normalizedArgumentsPayload(from: argumentsJSON)
        case .bridge:
            targetShortcutName = bridgeShortcutName
            payloadText = bridgePayload(for: tool, argumentsJSON: argumentsJSON, requestID: requestID)
        case .relay:
            targetShortcutName = tool.name
            payloadText = normalizedArgumentsPayload(from: argumentsJSON)
        }

        return await runShortcutAndAwaitCallback(
            requestID: requestID,
            targetShortcutName: targetShortcutName,
            payloadText: payloadText,
            originalToolName: tool.name,
            transport: transport
        )
    }

    private func runShortcutAndAwaitCallback(
        requestID: String,
        targetShortcutName: String,
        payloadText: String,
        originalToolName: String,
        transport: ShortcutExecutionTransport
    ) async -> ShortcutToolExecutionResult {
        let startAt = Date()

        guard let launchURL = buildRunShortcutURL(
            targetShortcutName: targetShortcutName,
            payloadText: payloadText,
            requestID: requestID,
            transport: transport
        ) else {
            return ShortcutToolExecutionResult(
                requestID: requestID,
                toolName: originalToolName,
                success: false,
                result: nil,
                errorMessage: ShortcutToolError.cannotOpenShortcutApp.localizedDescription,
                transport: transport,
                startedAt: startAt,
                finishedAt: Date()
            )
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ShortcutToolExecutionResult, Never>) in
            var pending = PendingExecution(
                requestID: requestID,
                toolName: originalToolName,
                transport: transport,
                startedAt: startAt,
                continuation: continuation,
                timeoutTask: nil
            )

            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.executionTimeoutSeconds * 1_000_000_000)
                self.resolvePendingAsTimeout(requestID: requestID)
            }
            pending.timeoutTask = timeoutTask
            pendingExecutions[requestID] = pending

            Task { [weak self] in
                guard let self else { return }
                let opened = await self.openSystemURL(launchURL)
                if !opened {
                    let failure = ShortcutToolExecutionResult(
                        requestID: requestID,
                        toolName: originalToolName,
                        success: false,
                        result: nil,
                        errorMessage: ShortcutToolError.cannotOpenShortcutApp.localizedDescription,
                        transport: transport,
                        startedAt: startAt,
                        finishedAt: Date()
                    )
                    self.resolvePending(requestID: requestID, result: failure)
                }
            }
        }

        return result
    }

    private func resolvePendingAsTimeout(requestID: String) {
        guard let pending = pendingExecutions[requestID] else { return }
        let result = ShortcutToolExecutionResult(
            requestID: requestID,
            toolName: pending.toolName,
            success: false,
            result: nil,
            errorMessage: ShortcutToolError.callbackTimeout.localizedDescription,
            transport: pending.transport,
            startedAt: pending.startedAt,
            finishedAt: Date()
        )
        resolvePending(requestID: requestID, result: result)
    }

    private func resolvePending(requestID: String, result: ShortcutToolExecutionResult) {
        guard var pending = pendingExecutions.removeValue(forKey: requestID) else { return }
        pending.timeoutTask?.cancel()
        pending.timeoutTask = nil
        pending.continuation.resume(returning: result)
    }

    private func buildRunShortcutURL(
        targetShortcutName: String,
        payloadText: String,
        requestID: String,
        transport: ShortcutExecutionTransport
    ) -> URL? {
        var callbackComponents = URLComponents()
        callbackComponents.scheme = ShortcutURLRouter.appScheme
        callbackComponents.host = "shortcuts"
        callbackComponents.path = "/callback"

        var successComponents = callbackComponents
        successComponents.queryItems = [
            URLQueryItem(name: "request_id", value: requestID),
            URLQueryItem(name: "status", value: "success"),
            URLQueryItem(name: "transport", value: transport.rawValue)
        ]

        var errorComponents = callbackComponents
        errorComponents.queryItems = [
            URLQueryItem(name: "request_id", value: requestID),
            URLQueryItem(name: "status", value: "error"),
            URLQueryItem(name: "transport", value: transport.rawValue)
        ]

        guard let successURL = successComponents.url?.absoluteString,
              let errorURL = errorComponents.url?.absoluteString else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: targetShortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: payloadText),
            URLQueryItem(name: "x-success", value: successURL),
            URLQueryItem(name: "x-error", value: errorURL)
        ]
        return components.url
    }

    private func bridgePayload(for tool: ShortcutToolDefinition, argumentsJSON: String, requestID: String) -> String {
        var payload: [String: JSONValue] = [
            "request_id": .string(requestID),
            "target_shortcut": .string(tool.name),
            "arguments_raw": .string(argumentsJSON),
            "source_app": .string("ETOS LLM Studio")
        ]

        if let decoded = try? decodeJSONDictionary(from: argumentsJSON), !decoded.isEmpty {
            payload["arguments"] = .dictionary(decoded)
        }

        if !tool.metadata.isEmpty {
            payload["tool_metadata"] = .dictionary(tool.metadata)
        }

        return JSONValue.dictionary(payload).prettyPrintedCompact()
    }

    private func normalizedArgumentsPayload(from argumentsJSON: String) -> String {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "{}"
        }
        return trimmed
    }

    private func formatResultText(_ text: String?) -> String {
        guard let text else { return "" }
        guard let data = text.data(using: .utf8) else { return text }

        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return value.prettyPrintedCompact()
        }
        return text
    }

    private func decodeJSONDictionary(from text: String) throws -> [String: JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let data = Data(trimmed.utf8)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func beginImportProgress() {
        isImporting = true
        importCancellationRequested = false
        importProgressCompleted = 0
        importProgressTotal = 0
        importCurrentItemName = nil
    }

    private func endImportProgress() {
        isImporting = false
        importCancellationRequested = false
        importCurrentItemName = nil
    }

    private func updateImportProgress(currentName: String?, increment: Int) {
        if let currentName {
            let trimmed = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
            importCurrentItemName = trimmed.isEmpty ? nil : trimmed
        }
        if increment > 0 {
            importProgressCompleted += increment
            if importProgressTotal > 0 {
                importProgressCompleted = min(importProgressCompleted, importProgressTotal)
            }
        }
    }

    private func ensureImportNotCancelled() throws {
        if Task.isCancelled || importCancellationRequested {
            throw CancellationError()
        }
    }

    private func decodeImportPayloads(from data: Data) throws -> [ShortcutToolImportPayload] {
        let decoder = JSONDecoder()

        if let manifest = try? decoder.decode(ShortcutToolManifest.self, from: data) {
            guard manifest.schemaVersion == 1 else {
                throw ShortcutToolError.unsupportedSchema(manifest.schemaVersion)
            }
            return manifest.tools
        }

        if let lightManifest = try? decoder.decode(ShortcutLightImportManifest.self, from: data),
           lightManifest.type == .light {
            return lightManifest.data.map { name in
                ShortcutToolImportPayload(
                    name: name,
                    metadata: ["importMode": .string("light")],
                    source: nil,
                    runModeHint: .direct
                )
            }
        }

        if let deepManifest = try? decoder.decode(ShortcutDeepImportManifest.self, from: data),
           deepManifest.type == .deep {
            return deepManifest.data.map { item in
                let link = item.link.trimmingCharacters(in: .whitespacesAndNewlines)
                var metadata: [String: JSONValue] = ["importMode": .string("deep")]
                if !link.isEmpty {
                    metadata["icloudLink"] = .string(link)
                }
                return ShortcutToolImportPayload(
                    name: item.name,
                    metadata: metadata,
                    source: nil,
                    runModeHint: .direct
                )
            }
        }

        throw ShortcutToolError.invalidManifest
    }

    private func enrichToolWithDeepScanIfNeeded(_ tool: ShortcutToolDefinition) async -> ShortcutToolDefinition {
        guard tool.metadata["importMode"]?.stringValue == "deep" else {
            return tool
        }
        guard let link = tool.metadata["icloudLink"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !link.isEmpty else {
            return tool
        }

        var next = tool
        var metadata = next.metadata

        if let summary = await fetchShortcutWorkflowSummary(fromICloudLink: link), !summary.isEmpty {
            next.source = summary
            metadata["scanStatus"] = .string("parsed")
            metadata["scanSource"] = .string("icloud_api")
        } else {
            if next.source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                next.source = "iCloud 分享链接：\(link)"
            }
            metadata["scanStatus"] = .string("link_only")
        }

        next.metadata = metadata
        return next
    }

    private func fetchShortcutWorkflowSummary(fromICloudLink link: String) async -> String? {
        guard let shortcutID = parseShortcutID(fromICloudLink: link) else { return nil }
        guard let recordURL = URL(string: "https://www.icloud.com/shortcuts/api/records/\(shortcutID)") else {
            return nil
        }

        do {
            var request = URLRequest(url: recordURL)
            request.timeoutInterval = 20
            let (recordData, recordResponse) = try await URLSession.shared.data(for: request)
            guard isSuccessStatusCode(recordResponse) else { return nil }

            let shortcutData = try await extractShortcutDataFromRecordPayload(recordData)
            guard let shortcutData else { return nil }
            return summarizeShortcutPlist(shortcutData)
        } catch {
            logger.warning("深度导入扫描失败: \(error.localizedDescription)")
            return nil
        }
    }

    private func parseShortcutID(fromICloudLink link: String) -> String? {
        guard let url = URL(string: link),
              let host = url.host?.lowercased(),
              host.contains("icloud.com") else {
            return nil
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let shortcutsIndex = components.firstIndex(of: "shortcuts"),
              components.indices.contains(shortcutsIndex + 1) else {
            return nil
        }
        let rawID = components[shortcutsIndex + 1]
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func extractShortcutDataFromRecordPayload(_ data: Data) async throws -> Data? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = root["fields"] as? [String: Any] else {
            return nil
        }

        if let encoded = nestedValue(fields, keyPath: ["data", "value"]) as? String,
           let decoded = Data(base64Encoded: encoded) {
            return decoded
        }

        let downloadURLString = (nestedValue(fields, keyPath: ["downloadURL", "value"]) as? String)
            ?? (nestedValue(fields, keyPath: ["downloadUrl", "value"]) as? String)
        guard let downloadURLString,
              let downloadURL = URL(string: downloadURLString) else {
            return nil
        }

        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 20
        let (downloadData, downloadResponse) = try await URLSession.shared.data(for: request)
        return isSuccessStatusCode(downloadResponse) ? downloadData : nil
    }

    private func nestedValue(_ dictionary: [String: Any], keyPath: [String]) -> Any? {
        var current: Any = dictionary
        for key in keyPath {
            guard let currentDict = current as? [String: Any],
                  let next = currentDict[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private func summarizeShortcutPlist(_ data: Data) -> String? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = object as? [String: Any] else {
            return nil
        }

        let workflowName = (root["WFWorkflowName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = (root["WFWorkflowActions"] as? [[String: Any]]) ?? []
        guard !actions.isEmpty else {
            if let workflowName, !workflowName.isEmpty {
                return "流程名：\(workflowName)。未解析到动作详情。"
            }
            return "未解析到动作详情。"
        }

        var orderedActionNames: [String] = []
        var seen = Set<String>()
        for action in actions {
            guard let identifier = action["WFWorkflowActionIdentifier"] as? String else { continue }
            let normalized = normalizeActionIdentifier(identifier)
            if seen.insert(normalized).inserted {
                orderedActionNames.append(normalized)
            }
        }

        let preview = orderedActionNames.prefix(12).joined(separator: "、")
        var fragments: [String] = []
        if let workflowName, !workflowName.isEmpty {
            fragments.append("流程名：\(workflowName)")
        }
        fragments.append("动作总数：\(actions.count)")
        if !preview.isEmpty {
            fragments.append("关键动作：\(preview)")
        }
        return fragments.joined(separator: "；")
    }

    private func normalizeActionIdentifier(_ identifier: String) -> String {
        let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let replaced = tail.replacingOccurrences(of: "_", with: " ")
        return replaced.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSuccessStatusCode(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - Helpers

    private func rebuildRouting() {
        var routes: [String: ShortcutToolDefinition] = [:]
        for tool in tools {
            let alias = ShortcutToolNaming.alias(for: tool)
            routes[alias] = tool
            routes["\(Self.toolNamePrefix)\(tool.id.uuidString)"] = tool
        }
        routedTools = routes
    }

    private func persistCurrentTools() {
        tools.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        ShortcutToolStore.saveTools(tools)
        rebuildRouting()
    }

    private func makeGeneratedDescription(from payload: ShortcutToolImportPayload) -> String {
        var parts: [String] = []

        if let type = payload.metadata["category"]?.stringValue, !type.isEmpty {
            parts.append("分类：\(type)")
        }
        if let capability = payload.metadata["capability"]?.stringValue, !capability.isEmpty {
            parts.append("能力：\(capability)")
        }
        if let source = payload.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
            let brief = source.count > 120 ? String(source.prefix(120)) + "..." : source
            parts.append("流程摘要：\(brief)")
        }

        if parts.isEmpty {
            return "执行快捷指令 \(payload.name)，用于完成自动化任务。"
        }
        return "执行快捷指令 \(payload.name)。\(parts.joined(separator: "；"))"
    }

    private func makeGeneratedDescription(for tool: ShortcutToolDefinition) -> String {
        makeGeneratedDescription(
            from: ShortcutToolImportPayload(
                name: tool.name,
                externalID: tool.externalID,
                metadata: tool.metadata,
                source: tool.source,
                runModeHint: tool.runModeHint
            )
        )
    }

    private func queryItem(named name: String, in url: URL?) -> String? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    private func parseNestedURLQueryItem(named name: String, in url: URL?) -> URL? {
        guard let value = queryItem(named: name, in: url) else { return nil }
        return URL(string: value)
    }

    private func notifyImportCallback(
        summary: ShortcutImportSummary,
        triggerURL: URL?,
        success: Bool,
        errorMessage: String?
    ) async {
        guard let callbackURL = parseNestedURLQueryItem(named: success ? "x_success" : "x_error", in: triggerURL) else {
            return
        }

        guard var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            return
        }

        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "imported", value: "\(summary.importedCount)"))
        query.append(URLQueryItem(name: "skipped", value: "\(summary.skippedCount)"))
        query.append(URLQueryItem(name: "invalid", value: "\(summary.invalidCount)"))
        if !summary.conflictNames.isEmpty {
            query.append(URLQueryItem(name: "conflicts", value: summary.conflictNames.joined(separator: ",")))
        }
        if let errorMessage, !errorMessage.isEmpty {
            query.append(URLQueryItem(name: "error", value: errorMessage))
        }
        components.queryItems = query

        guard let finalURL = components.url else { return }
        _ = await openSystemURL(finalURL)
    }

    private func clipboardText() -> String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #else
        return nil
        #endif
    }

    private func openSystemURL(_ url: URL) async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
        #elseif os(watchOS)
        WKExtension.shared().openSystemURL(url)
        return true
        #else
        return false
        #endif
    }
}

private extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}
