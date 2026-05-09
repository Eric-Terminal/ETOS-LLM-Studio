// ============================================================================
// AppToolManager.swift
// ============================================================================
// 本地拓展工具管理器。
// - 管理默认关闭的本地拓展工具目录
// - 负责聊天工具暴露与执行分发
// ============================================================================

import Foundation
import Combine
import os.log

@MainActor
public final class AppToolManager: ObservableObject {
    public static let shared = AppToolManager()
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则工具中心里的总开关、启用态与审批策略不会稳定自动刷新。

    nonisolated static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AppToolManager")
    nonisolated static let chatToolsEnabledUserDefaultsKey = "appTools.chatToolsEnabled"
    nonisolated static let enabledToolIDsUserDefaultsKey = "appTools.enabledToolIDs"
    nonisolated static let toolApprovalPoliciesUserDefaultsKey = "appTools.toolApprovalPolicies"
    // 记录已经向用户"首次引入"过的默认工具 ID，防止每次启动都强制重新启用
    nonisolated static let knownDefaultToolIDsUserDefaultsKey = "appTools.knownDefaultToolIDs"
    #if os(watchOS)
    nonisolated static let defaultEnabledToolKinds: Set<AppToolKind> = [.askUserInput, .getSystemTime]
    #else
    nonisolated static let defaultEnabledToolKinds: Set<AppToolKind> = [.showWidget, .askUserInput, .getSystemTime]
    #endif
    nonisolated static let builtInToolKinds: Set<AppToolKind> = [.showWidget, .askUserInput, .getSystemTime]

    @Published public internal(set) var chatToolsEnabled: Bool
    @Published var enabledToolIDs: Set<String>
    @Published var toolApprovalPolicies: [String: AppToolApprovalPolicy]

    private init(defaults: UserDefaults = .standard) {
        chatToolsEnabled = defaults.object(forKey: Self.chatToolsEnabledUserDefaultsKey) as? Bool ?? true
        let allDefaultIDs = Set(Self.defaultEnabledToolKinds.map(\.rawValue))
        // 只对"从未见过"的默认工具（版本升级新增）强制启用，已知工具尊重用户自行关闭的设置
        let knownDefaultIDs = Set(defaults.stringArray(forKey: Self.knownDefaultToolIDsUserDefaultsKey) ?? [])
        let newDefaultIDs = allDefaultIDs.subtracting(knownDefaultIDs)
        if let storedIDs = defaults.stringArray(forKey: Self.enabledToolIDsUserDefaultsKey) {
            var migratedIDs = Set(storedIDs.filter { AppToolKind(rawValue: $0) != nil })
            migratedIDs.formUnion(newDefaultIDs)
            enabledToolIDs = migratedIDs
            defaults.set(Array(migratedIDs).sorted(), forKey: Self.enabledToolIDsUserDefaultsKey)
        } else {
            enabledToolIDs = allDefaultIDs
            defaults.set(Array(allDefaultIDs).sorted(), forKey: Self.enabledToolIDsUserDefaultsKey)
        }
        // 标记当前所有默认工具为"已知"，下次启动不再重复强制启用
        defaults.set(Array(allDefaultIDs).sorted(), forKey: Self.knownDefaultToolIDsUserDefaultsKey)
        let storedPolicyRawValues = defaults.dictionary(forKey: Self.toolApprovalPoliciesUserDefaultsKey) as? [String: String] ?? [:]
        toolApprovalPolicies = storedPolicyRawValues.reduce(into: [String: AppToolApprovalPolicy]()) { result, pair in
            guard let kind = AppToolKind(rawValue: pair.key) else { return }
            guard kind.requiresApproval else { return }
            guard let policy = AppToolApprovalPolicy(rawValue: pair.value), policy != .askEveryTime else { return }
            result[pair.key] = policy
        }
    }

    public nonisolated static func isAppToolName(_ name: String) -> Bool {
        AppToolKind.resolve(from: name) != nil
    }

    public nonisolated static func isBuiltInToolName(_ name: String) -> Bool {
        guard let kind = AppToolKind.resolve(from: name) else { return false }
        return builtInToolKinds.contains(kind)
    }

    public var tools: [AppToolCatalogItem] {
        AppToolKind.allCases.filter { !Self.builtInToolKinds.contains($0) }.map { kind in
            AppToolCatalogItem(kind: kind, isEnabled: enabledToolIDs.contains(kind.rawValue))
        }
    }

    internal var enabledToolKinds: Set<AppToolKind> {
        Set(enabledToolIDs.compactMap(AppToolKind.init(rawValue:)))
    }

    internal var configuredApprovalPoliciesByKind: [AppToolKind: AppToolApprovalPolicy] {
        toolApprovalPolicies.reduce(into: [AppToolKind: AppToolApprovalPolicy]()) { result, pair in
            guard let kind = AppToolKind(rawValue: pair.key) else { return }
            result[kind] = pair.value
        }
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

    public func approvalPolicy(for kind: AppToolKind) -> AppToolApprovalPolicy {
        guard kind.requiresApproval else { return .alwaysAllow }
        return toolApprovalPolicies[kind.rawValue] ?? .askEveryTime
    }

    public func approvalPolicy(for toolName: String) -> AppToolApprovalPolicy? {
        guard let kind = AppToolKind.resolve(from: toolName) else { return nil }
        return approvalPolicy(for: kind)
    }

    public func setToolApprovalPolicy(kind: AppToolKind, policy: AppToolApprovalPolicy) {
        guard kind.requiresApproval else {
            if toolApprovalPolicies[kind.rawValue] != nil {
                toolApprovalPolicies.removeValue(forKey: kind.rawValue)
                persistToolApprovalPolicies()
            }
            return
        }
        if policy == .askEveryTime {
            toolApprovalPolicies.removeValue(forKey: kind.rawValue)
        } else {
            toolApprovalPolicies[kind.rawValue] = policy
        }
        persistToolApprovalPolicies()
        Self.logger.info("拓展工具 \(kind.rawValue, privacy: .public) 审批策略已更新为 \(policy.rawValue, privacy: .public)。")
    }

    public func chatToolsForLLM() -> [InternalToolDefinition] {
        guard chatToolsEnabled else { return [] }
        return tools
            .filter(\.isEnabled)
            .filter { approvalPolicy(for: $0.kind) != .alwaysDeny }
            .map { item in toolDefinition(for: item.kind) }
    }

    public func builtInToolsForLLM() -> [InternalToolDefinition] {
        var tools: [InternalToolDefinition] = []
        if isToolEnabled(.showWidget) {
            tools.append(toolDefinition(for: .showWidget))
        }
        if isToolEnabled(.askUserInput) {
            tools.append(toolDefinition(for: .askUserInput))
        }
        if isToolEnabled(.getSystemTime) {
            tools.append(toolDefinition(for: .getSystemTime))
        }
        return tools
    }

    public func displayLabel(for toolName: String) -> String? {
        AppToolKind.resolve(from: toolName)?.displayName
    }

    public func executeToolFromChat(toolName: String, argumentsJSON: String) async throws -> String {
        guard let kind = AppToolKind.resolve(from: toolName) else {
            throw AppToolExecutionError.unknownTool
        }
        if !Self.builtInToolKinds.contains(kind) && !chatToolsEnabled {
            throw AppToolExecutionError.toolGroupDisabled
        }
        guard isToolEnabled(kind) else {
            throw AppToolExecutionError.toolDisabled(kind.displayName)
        }
        if approvalPolicy(for: kind) == .alwaysDeny {
            throw AppToolExecutionError.toolDeniedByPolicy(kind.displayName)
        }

        return try await Self.executeResolvedTool(
            kind: kind,
            argumentsJSON: argumentsJSON,
            current: self
        )
    }
}
