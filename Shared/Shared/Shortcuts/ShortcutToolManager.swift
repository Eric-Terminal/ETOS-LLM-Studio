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
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则快捷指令导入进度、工具列表与启用状态不会稳定自动刷新。

    public nonisolated static var toolNamePrefix: String { "shortcut://" }
    public nonisolated static var toolAliasPrefix: String { ShortcutToolNaming.toolAliasPrefix }
    public nonisolated static let officialImportShortcutShareURLString = "https://www.icloud.com/shortcuts/22ebff9dcd6a4d3aa096d3f15d34a94e"
    public nonisolated static let officialImportShortcutDefaultName = "ELS Export"
    private nonisolated static let chatToolsEnabledUserDefaultsKey = "shortcut.chatToolsEnabled"

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ShortcutToolManager")
    let executionTimeoutSeconds: UInt64 = 45
    let officialImportShortcutNameUserDefaultsKey = "shortcut.officialImportShortcutName"

    @Published public internal(set) var tools: [ShortcutToolDefinition] = []
    @Published public private(set) var lastImportSummary: ShortcutImportSummary?
    @Published public private(set) var lastExecutionResult: ShortcutToolExecutionResult? {
        didSet {
            guard let lastExecutionResult else { return }
            DailyPulseManager.shared.appendExternalSignal(
                DailyPulseExternalSignal(
                    source: .shortcutResult,
                    title: lastExecutionResult.toolName,
                    preview: lastExecutionResult.success
                        ? (lastExecutionResult.result ?? "执行成功，但没有返回可展示内容。")
                        : (lastExecutionResult.errorMessage ?? "执行失败，但没有返回详细错误。"),
                    capturedAt: lastExecutionResult.finishedAt,
                    isFailure: !lastExecutionResult.success
                )
            )
        }
    }
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var lastOfficialTemplateStatusMessage: String?
    @Published public private(set) var lastOfficialTemplateRunSucceeded: Bool?
    @Published public internal(set) var isImporting: Bool = false
    @Published public internal(set) var isCancellingImport: Bool = false
    @Published public internal(set) var importProgressCompleted: Int = 0
    @Published public internal(set) var importProgressTotal: Int = 0
    @Published public internal(set) var importCurrentItemName: String?
    @Published public private(set) var chatToolsEnabled: Bool

    var routedTools: [String: ShortcutToolDefinition] = [:]
    var pendingExecutions: [String: PendingExecution] = [:]
    var importCancellationRequested = false

    struct PendingExecution {
        let requestID: String
        let toolName: String
        let transport: ShortcutExecutionTransport
        let startedAt: Date
        let continuation: CheckedContinuation<ShortcutToolExecutionResult, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private init() {
        chatToolsEnabled = AppConfigStore.boolValue(
            for: .shortcutChatToolsEnabled,
            legacyUserDefaultsKey: Self.chatToolsEnabledUserDefaultsKey,
            defaultValue: true
        )
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
            let value = AppConfigStore.textValue(
                for: .shortcutBridgeShortcutName,
                defaultValue: "ETOS Shortcut Bridge"
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "ETOS Shortcut Bridge" : value
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            AppConfigStore.persistSynchronously(
                .text(trimmed.isEmpty ? "ETOS Shortcut Bridge" : trimmed),
                for: .shortcutBridgeShortcutName
            )
        }
    }

    public var officialImportShortcutShareURL: URL {
        URL(string: Self.officialImportShortcutShareURLString)!
    }

    public var officialImportShortcutName: String {
        get {
            let value = AppConfigStore.textValue(
                for: .shortcutOfficialImportShortcutName,
                legacyUserDefaultsKey: officialImportShortcutNameUserDefaultsKey,
                defaultValue: Self.officialImportShortcutDefaultName
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? Self.officialImportShortcutDefaultName : value
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = trimmed.isEmpty ? Self.officialImportShortcutDefaultName : trimmed
            AppConfigStore.persistSynchronously(.text(next), for: .shortcutOfficialImportShortcutName)
            objectWillChange.send()
        }
    }

    public func setChatToolsEnabled(_ isEnabled: Bool) {
        guard chatToolsEnabled != isEnabled else { return }
        chatToolsEnabled = isEnabled
        AppConfigStore.persistSynchronously(.bool(isEnabled), for: .shortcutChatToolsEnabled)
        logger.info("快捷指令聊天工具总开关已\(isEnabled ? "开启" : "关闭")。")
    }

    public func reloadAppConfigBackedState() {
        chatToolsEnabled = AppConfigStore.boolValue(
            for: .shortcutChatToolsEnabled,
            legacyUserDefaultsKey: Self.chatToolsEnabledUserDefaultsKey,
            defaultValue: true
        )
        objectWillChange.send()
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
        isCancellingImport = true
        logger.warning("收到快捷指令导入取消请求。")
    }

    @discardableResult
    public func runOfficialImportShortcut() async -> Bool {
        guard let runURL = buildOfficialImportRunShortcutURL() else {
            let message = NSLocalizedString("未能运行导入快捷指令。请先下载并添加该快捷指令，或确认名称配置正确。", comment: "")
            lastOfficialTemplateRunSucceeded = false
            lastOfficialTemplateStatusMessage = message
            lastErrorMessage = message
            return false
        }

        logger.info("尝试运行官方导入快捷指令，name=\(self.officialImportShortcutName, privacy: .public)")
        lastOfficialTemplateRunSucceeded = nil
        lastOfficialTemplateStatusMessage = NSLocalizedString("正在启动官方导入快捷指令…", comment: "")

        let opened = await openSystemURL(runURL)
        if opened {
            logger.info("已成功拉起官方导入快捷指令。")
            lastOfficialTemplateStatusMessage = NSLocalizedString("已拉起快捷指令，请在授权后返回应用继续导入。", comment: "")
            return true
        }

        logger.error("拉起官方导入快捷指令失败。")
        let message = NSLocalizedString("未能运行导入快捷指令。请先下载并添加该快捷指令，或确认名称配置正确。", comment: "")
        lastOfficialTemplateRunSucceeded = false
        lastOfficialTemplateStatusMessage = message
        lastErrorMessage = message
        return false
    }

    // MARK: - Import

    @discardableResult
    public func importFromClipboard(triggerURL: URL?) async -> ShortcutImportSummary {
        if isImporting {
            let summary = ShortcutImportSummary(importedCount: 0, skippedCount: 0, conflictNames: [], invalidCount: 0)
            lastImportSummary = summary
            lastErrorMessage = NSLocalizedString("当前已有导入任务正在进行。", comment: "")
            logger.warning("忽略导入请求：已有导入任务在进行中。")
            return summary
        }

        beginImportProgress()
        defer { endImportProgress() }

        do {
            let fromOfficialTemplate = (queryItem(named: "from", in: triggerURL)?.lowercased() == "official_template")
            if fromOfficialTemplate {
                lastOfficialTemplateRunSucceeded = true
                lastOfficialTemplateStatusMessage = NSLocalizedString("已收到官方导入回调，正在读取剪贴板…", comment: "")
            }

            let source = queryItem(named: "source", in: triggerURL)?.lowercased() ?? "clipboard"
            logger.info("开始导入快捷指令，source=\(source, privacy: .public)")
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
            logger.info("导入清单解析完成，共 \(importedPayloads.count) 项。")
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
                    isEnabled: true,
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
                    try ensureImportNotCancelled()
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
            logger.info("快捷指令导入完成：新增 \(imported) 条，跳过 \(skipped) 条，无效 \(invalid) 条。")
            if fromOfficialTemplate {
                lastOfficialTemplateRunSucceeded = true
                lastOfficialTemplateStatusMessage = NSLocalizedString("官方导入完成：已处理剪贴板数据。", comment: "")
            }

            await notifyImportCallback(summary: summary, triggerURL: triggerURL, success: true, errorMessage: nil)
            return summary
        } catch is CancellationError {
            let summary = ShortcutImportSummary(importedCount: 0, skippedCount: 0, conflictNames: [], invalidCount: 0)
            lastImportSummary = summary
            lastErrorMessage = NSLocalizedString("导入已取消。", comment: "")
            logger.warning("快捷指令导入已取消。")
            await notifyImportCallback(summary: summary, triggerURL: triggerURL, success: false, errorMessage: lastErrorMessage)
            return summary
        } catch {
            let summary = ShortcutImportSummary(importedCount: 0, skippedCount: 0, conflictNames: [], invalidCount: 0)
            lastImportSummary = summary
            lastErrorMessage = error.localizedDescription
            logger.error("快捷指令导入失败：\(error.localizedDescription, privacy: .public)")
            if queryItem(named: "from", in: triggerURL)?.lowercased() == "official_template" {
                lastOfficialTemplateRunSucceeded = false
                lastOfficialTemplateStatusMessage = error.localizedDescription
            }
            await notifyImportCallback(summary: summary, triggerURL: triggerURL, success: false, errorMessage: error.localizedDescription)
            return summary
        }
    }

    // MARK: - Chat Integration

    public func chatToolsForLLM() -> [InternalToolDefinition] {
        guard chatToolsEnabled else { return [] }
        let chatTools: [InternalToolDefinition] = tools
            .filter { $0.isEnabled }
            .map { tool in
                let alias = ShortcutToolNaming.alias(for: tool)
                let prefix = NSLocalizedString("[快捷指令]", comment: "Shortcut tool description prefix sent to model")
                let description = ModelPromptLanguage.appendingToolArgumentInstruction(to: "\(prefix) \(tool.effectiveDescription)")
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
        return chatTools
    }

    public func displayLabel(for toolName: String) -> String? {
        guard let tool = routedTools[toolName] else { return nil }
        return "[快捷指令] \(tool.displayName)"
    }

    public func executeToolFromChat(toolName: String, argumentsJSON: String) async throws -> String {
        guard chatToolsEnabled else {
            throw ShortcutToolError.executionFailed(NSLocalizedString("快捷指令工具总开关已关闭。", comment: ""))
        }
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
        guard chatToolsEnabled else {
            return ShortcutToolExecutionResult(
                requestID: request.requestID,
                toolName: request.toolName,
                success: false,
                result: nil,
                errorMessage: NSLocalizedString("快捷指令工具总开关已关闭。", comment: ""),
                transport: .relay,
                startedAt: request.requestedAt,
                finishedAt: Date()
            )
        }
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

    @discardableResult
    public func handleOfficialTemplateStatusURL(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "shortcuts" else { return false }
        guard url.path.lowercased() == "/template-status" else { return false }

        let status = queryItem(named: "status", in: url)?.lowercased() ?? "error"
        if status == "success" {
            logger.info("收到官方导入状态回调：success")
            lastOfficialTemplateRunSucceeded = true
            lastOfficialTemplateStatusMessage = queryItem(named: "message", in: url)
                ?? NSLocalizedString("已拉起快捷指令，请在授权后返回应用继续导入。", comment: "")
            return true
        }

        let callbackError = queryItem(named: "errorMessage", in: url)
            ?? queryItem(named: "error", in: url)
            ?? queryItem(named: "message", in: url)
        let message: String
        if let callbackError,
           !callbackError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = callbackError
        } else {
            message = NSLocalizedString("未能运行导入快捷指令。请先下载并添加该快捷指令，或确认名称配置正确。", comment: "")
        }

        logger.warning("收到官方导入状态回调：error，message=\(message, privacy: .public)")
        lastOfficialTemplateRunSucceeded = false
        lastOfficialTemplateStatusMessage = message
        lastErrorMessage = message
        return true
    }

}
