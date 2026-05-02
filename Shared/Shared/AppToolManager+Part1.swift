import Foundation
import Combine
import os.log
import SQLite3

extension AppToolManager {
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

}
