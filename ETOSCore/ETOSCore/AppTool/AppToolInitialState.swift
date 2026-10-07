import Foundation

struct AppToolInitialState: Sendable {
    let chatToolsEnabled: Bool
    let enabledToolIDs: Set<String>
    let approvalPolicies: [String: AppToolApprovalPolicy]
    let customJSTools: [AppToolCustomJSTool]

    static func load(registerNewDefaults: Bool) -> AppToolInitialState {
        let enabled = AppConfigStore.boolValue(for: .appToolsChatToolsEnabled,
                                              legacyUserDefaultsKey: AppToolManager.chatToolsEnabledUserDefaultsKey, defaultValue: true)
        let defaults = Set(AppToolManager.defaultEnabledToolKinds.map(\.rawValue))
        let stored = AppConfigStore.stringArrayValue(for: .appToolsEnabledToolIDs,
                                                   legacyUserDefaultsKey: AppToolManager.enabledToolIDsUserDefaultsKey,
                                                   defaultValue: Array(defaults))
        var ids = Set((stored ?? Array(defaults)).filter { AppToolKind(rawValue: $0) != nil })
        if registerNewDefaults {
            let known = Set(AppConfigStore.stringArrayValue(for: .appToolsKnownDefaultToolIDs,
                                                          legacyUserDefaultsKey: AppToolManager.knownDefaultToolIDsUserDefaultsKey,
                                                          defaultValue: []) ?? [])
            ids = migratedEnabledIDs(stored: stored, knownDefaults: known, defaults: defaults)
            AppConfigStore.persistStringArray(Array(ids).sorted(), for: .appToolsEnabledToolIDs)
            AppConfigStore.persistStringArray(Array(defaults).sorted(), for: .appToolsKnownDefaultToolIDs)
        }
        let rawPolicies = AppConfigStore.stringDictionaryValue(for: .appToolsToolApprovalPolicies,
                                                              legacyUserDefaultsKey: AppToolManager.toolApprovalPoliciesUserDefaultsKey)
        let policies = rawPolicies.reduce(into: [String: AppToolApprovalPolicy]()) { result, pair in
            guard let kind = AppToolKind(rawValue: pair.key), kind.requiresApproval,
                  let policy = AppToolApprovalPolicy(rawValue: pair.value), policy != .askEveryTime else { return }
            result[pair.key] = policy
        }
        return AppToolInitialState(chatToolsEnabled: enabled, enabledToolIDs: ids, approvalPolicies: policies,
                                   customJSTools: AppToolManager.loadCustomJSToolsFromDisk())
    }

    /// 只引入用户尚未见过的默认工具，已知且已关闭的工具不能在启动时复活。
    static func migratedEnabledIDs(stored: [String]?, knownDefaults: Set<String>, defaults: Set<String>) -> Set<String> {
        guard let stored else { return defaults }
        return Set(stored.filter { AppToolKind(rawValue: $0) != nil }).union(defaults.subtracting(knownDefaults))
    }
}
