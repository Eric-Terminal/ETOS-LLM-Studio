// ============================================================================
// AppToolManager.swift
// ============================================================================
// 本地拓展工具管理器。
// - 管理默认关闭的本地拓展工具目录
// - 负责聊天工具暴露与执行分发
// ============================================================================

import Foundation
import os.log

public enum AppToolKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case echoText = "echo_text"

    public var id: String { rawValue }

    public var toolName: String {
        switch self {
        case .echoText:
            return "app_echo_text"
        }
    }

    public var displayName: String {
        switch self {
        case .echoText:
            return NSLocalizedString("示例：文本回显", comment: "Example echo tool name")
        }
    }

    public var summary: String {
        switch self {
        case .echoText:
            return NSLocalizedString("把传入文本原样返回，用于验证拓展工具链路是否正常。", comment: "Example echo tool summary")
        }
    }

    public var detailDescription: String {
        switch self {
        case .echoText:
            return NSLocalizedString("示例工具详情：文本回显", comment: "Example echo tool detail description")
        }
    }

    public var parameters: JSONValue {
        switch self {
        case .echoText:
            return JSONValue.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "text": .dictionary([
                        "type": .string("string"),
                        "description": .string(NSLocalizedString("要原样返回的文本内容。", comment: "Example echo tool text parameter description"))
                    ])
                ]),
                "required": .array([.string("text")])
            ])
        }
    }

    public var toolDescription: String {
        switch self {
        case .echoText:
            return NSLocalizedString(
                "示例工具：把 text 参数中的文本原样返回，仅用于验证本地拓展工具链路与参数生成是否正常。",
                comment: "Example echo tool description sent to model"
            )
        }
    }

    fileprivate static func resolve(from toolName: String) -> AppToolKind? {
        allCases.first(where: { $0.toolName == toolName })
    }
}

public struct AppToolCatalogItem: Identifiable, Equatable, Sendable {
    public let kind: AppToolKind
    public let isEnabled: Bool

    public var id: AppToolKind { kind }

    public init(kind: AppToolKind, isEnabled: Bool) {
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

public enum AppToolExecutionError: LocalizedError {
    case toolGroupDisabled
    case toolDisabled(String)
    case unknownTool
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .toolGroupDisabled:
            return NSLocalizedString("拓展工具总开关已关闭。", comment: "App tools group disabled")
        case .toolDisabled(let name):
            return String(
                format: NSLocalizedString("拓展工具“%@”当前未启用。", comment: "App tool disabled"),
                name
            )
        case .unknownTool:
            return NSLocalizedString("未找到对应的拓展工具。", comment: "Unknown app tool")
        case .invalidArguments(let message):
            return message
        }
    }
}

@MainActor
public final class AppToolManager: ObservableObject {
    public static let shared = AppToolManager()

    private nonisolated static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AppToolManager")
    private nonisolated static let chatToolsEnabledUserDefaultsKey = "appTools.chatToolsEnabled"
    private nonisolated static let enabledToolIDsUserDefaultsKey = "appTools.enabledToolIDs"

    @Published public private(set) var chatToolsEnabled: Bool
    @Published private var enabledToolIDs: Set<String>

    private init(defaults: UserDefaults = .standard) {
        chatToolsEnabled = defaults.object(forKey: Self.chatToolsEnabledUserDefaultsKey) as? Bool ?? true
        let storedIDs = defaults.stringArray(forKey: Self.enabledToolIDsUserDefaultsKey) ?? []
        enabledToolIDs = Set(storedIDs.filter { AppToolKind(rawValue: $0) != nil })
    }

    public nonisolated static func isAppToolName(_ name: String) -> Bool {
        AppToolKind.resolve(from: name) != nil
    }

    public var tools: [AppToolCatalogItem] {
        AppToolKind.allCases.map { kind in
            AppToolCatalogItem(kind: kind, isEnabled: enabledToolIDs.contains(kind.rawValue))
        }
    }

    internal var enabledToolKinds: Set<AppToolKind> {
        Set(enabledToolIDs.compactMap(AppToolKind.init(rawValue:)))
    }

    public func setChatToolsEnabled(_ isEnabled: Bool) {
        guard chatToolsEnabled != isEnabled else { return }
        chatToolsEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.chatToolsEnabledUserDefaultsKey)
        Self.logger.info("本地拓展工具总开关已\(isEnabled ? "开启" : "关闭")。")
    }

    public func isToolEnabled(_ kind: AppToolKind) -> Bool {
        enabledToolIDs.contains(kind.rawValue)
    }

    public func setToolEnabled(kind: AppToolKind, isEnabled: Bool) {
        if isEnabled {
            enabledToolIDs.insert(kind.rawValue)
        } else {
            enabledToolIDs.remove(kind.rawValue)
        }
        persistEnabledToolIDs()
        Self.logger.info("拓展工具 \(kind.rawValue, privacy: .public) 已\(isEnabled ? "启用" : "禁用")。")
    }

    public func chatToolsForLLM() -> [InternalToolDefinition] {
        guard chatToolsEnabled else { return [] }
        return tools
            .filter(\.isEnabled)
            .map { item in
                InternalToolDefinition(
                    name: item.kind.toolName,
                    description: item.kind.toolDescription,
                    parameters: item.kind.parameters,
                    isBlocking: false
                )
            }
    }

    public func displayLabel(for toolName: String) -> String? {
        AppToolKind.resolve(from: toolName)?.displayName
    }

    public func executeToolFromChat(toolName: String, argumentsJSON: String) async throws -> String {
        guard chatToolsEnabled else {
            throw AppToolExecutionError.toolGroupDisabled
        }
        guard let kind = AppToolKind.resolve(from: toolName) else {
            throw AppToolExecutionError.unknownTool
        }
        guard isToolEnabled(kind) else {
            throw AppToolExecutionError.toolDisabled(kind.displayName)
        }

        switch kind {
        case .echoText:
            struct EchoArgs: Decodable {
                let text: String
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(EchoArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 echo_text 的参数，请提供 text 字段。", comment: "Echo tool invalid arguments")
                )
            }

            let text = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：echo_text 的 text 不能为空。", comment: "Echo tool empty text")
                )
            }

            return String(
                format: NSLocalizedString("文本回显结果：%@", comment: "Echo tool result format"),
                text
            )
        }
    }

    internal func restoreStateForTests(chatToolsEnabled: Bool, enabledKinds: Set<AppToolKind>) {
        self.chatToolsEnabled = chatToolsEnabled
        enabledToolIDs = Set(enabledKinds.map(\.rawValue))
        UserDefaults.standard.set(chatToolsEnabled, forKey: Self.chatToolsEnabledUserDefaultsKey)
        UserDefaults.standard.set(Array(enabledToolIDs).sorted(), forKey: Self.enabledToolIDsUserDefaultsKey)
        objectWillChange.send()
    }

    private func persistEnabledToolIDs() {
        UserDefaults.standard.set(Array(enabledToolIDs).sorted(), forKey: Self.enabledToolIDsUserDefaultsKey)
        objectWillChange.send()
    }
}
