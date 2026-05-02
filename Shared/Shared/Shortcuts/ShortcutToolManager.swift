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
    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ShortcutToolManager")
    let executionTimeoutSeconds: UInt64 = 45
    let bridgeShortcutUserDefaultsKey = "shortcut.bridgeShortcutName"
    let officialImportShortcutNameUserDefaultsKey = "shortcut.officialImportShortcutName"

    @Published public var tools: [ShortcutToolDefinition] = []
    @Published public var lastImportSummary: ShortcutImportSummary?
    @Published public var lastExecutionResult: ShortcutToolExecutionResult? {
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
    @Published public var lastErrorMessage: String?
    @Published public var lastOfficialTemplateStatusMessage: String?
    @Published public var lastOfficialTemplateRunSucceeded: Bool?
    @Published public var isImporting: Bool = false
    @Published public var isCancellingImport: Bool = false
    @Published public var importProgressCompleted: Int = 0
    @Published public var importProgressTotal: Int = 0
    @Published public var importCurrentItemName: String?
    @Published public var chatToolsEnabled: Bool

    var routedTools: [String: ShortcutToolDefinition] = [:]
    var pendingExecutions: [String: PendingExecution] = [:]
    var importCancellationRequested = false

    init() {
        chatToolsEnabled = UserDefaults.standard.object(forKey: Self.chatToolsEnabledUserDefaultsKey) as? Bool ?? true
        reloadFromDisk()
    }
}

extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}
