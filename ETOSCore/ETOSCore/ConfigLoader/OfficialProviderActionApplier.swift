// ============================================================================
// OfficialProviderActionApplier.swift
// ============================================================================
// 将官方 Provider 配方预览并以单个配置数据库事务应用。
// ============================================================================

import Foundation
import GRDB

enum OfficialDataActionApplyError: LocalizedError {
    case metadataMismatch
    case unsupportedRevision
    case changedRevision
    case duplicateProvider
    case persistenceUnavailable

    var errorDescription: String? {
        switch self {
        case .metadataMismatch:
            return NSLocalizedString("官方操作清单与操作内容不一致。", comment: "Official action metadata mismatch")
        case .unsupportedRevision:
            return NSLocalizedString("官方操作版本低于此设备已应用的版本。", comment: "Official action revision rollback")
        case .changedRevision:
            return NSLocalizedString("同一版本的官方操作内容发生了变化。", comment: "Official action immutable revision changed")
        case .duplicateProvider:
            return NSLocalizedString("官方操作包含重复的提供商。", comment: "Official action duplicate provider")
        case .persistenceUnavailable:
            return NSLocalizedString("当前无法访问提供商数据库。", comment: "Official action persistence unavailable")
        }
    }
}

struct OfficialDataActionStoredState {
    let actionID: String
    let revision: Int
    let payloadSHA256: String
    let providerID: UUID
    let officialSnapshot: Provider
}

struct OfficialProviderMergeResult {
    let provider: Provider?
    let outcome: OfficialProviderActionOutcome
    let preview: OfficialDataPreviewOperation
}

enum OfficialProviderActionApplier {
    static func preview(
        preparedActions: [PreparedOfficialDataAction],
        trigger: OfficialDataSyncTrigger
    ) throws -> [OfficialDataPreviewOperation] {
        guard let result = Persistence.withConfigDatabaseRead({ db in
            let providers = try ConfigLoader.loadProvidersFromRelationalStore(
                db,
                storedProviderOrderIDs: AppConfigStore.stringArrayValue(for: .providerOrderIDs, defaultValue: []) ?? []
            )
            let states = try loadStates(db)
            return try mergeActions(
                preparedActions,
                trigger: trigger,
                startingProviders: providers,
                states: states
            ).previews
        }) else {
            throw OfficialDataActionApplyError.persistenceUnavailable
        }
        return result
    }

    static func apply(
        preparedActions: [PreparedOfficialDataAction],
        trigger: OfficialDataSyncTrigger
    ) throws -> OfficialDataActionSummary {
        guard !preparedActions.isEmpty else { return .empty }

        let transactionResult = Persistence.withConfigDatabaseWrite { db in
            let providers = try ConfigLoader.loadProvidersFromRelationalStore(
                db,
                storedProviderOrderIDs: AppConfigStore.stringArrayValue(for: .providerOrderIDs, defaultValue: []) ?? []
            )
            let states = try loadStates(db)
            let merged = try mergeActions(
                preparedActions,
                trigger: trigger,
                startingProviders: providers,
                states: states
            )

            if merged.didChangeProviders {
                try ConfigLoader.replaceProvidersInRelationalStore(db, providers: merged.providers)
            }
            for applied in merged.appliedStates {
                try db.execute(
                    sql: "DELETE FROM official_data_action_state WHERE provider_id = ? AND action_id <> ?",
                    arguments: [applied.providerID.uuidString, applied.actionID]
                )
                try db.execute(
                    sql: """
                        INSERT INTO official_data_action_state (
                            action_id, revision, payload_sha256, provider_id,
                            official_snapshot_json, applied_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(action_id) DO UPDATE SET
                            revision = excluded.revision,
                            payload_sha256 = excluded.payload_sha256,
                            provider_id = excluded.provider_id,
                            official_snapshot_json = excluded.official_snapshot_json,
                            applied_at = excluded.applied_at
                    """,
                    arguments: [
                        applied.actionID,
                        applied.revision,
                        applied.payloadSHA256,
                        applied.providerID.uuidString,
                        applied.snapshotJSON,
                        Date().timeIntervalSince1970
                    ]
                )
            }
            return (merged.summary, merged.providers.map { $0.id.uuidString })
        }

        guard let transactionResult else {
            throw OfficialDataActionApplyError.persistenceUnavailable
        }

        ConfigLoader.removeLegacyProviderBlobs()
        ConfigLoader.cleanupLegacyProviderFiles()
        ConfigLoader.reconcileStoredProviderOrder(currentIDs: transactionResult.1)
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        return transactionResult.0
    }

    private struct AppliedState {
        let actionID: String
        let revision: Int
        let payloadSHA256: String
        let providerID: UUID
        let snapshotJSON: String
    }

    private struct MergeActionsResult {
        let providers: [Provider]
        let previews: [OfficialDataPreviewOperation]
        let appliedStates: [AppliedState]
        let summary: OfficialDataActionSummary
        let didChangeProviders: Bool
    }

    private static func mergeActions(
        _ preparedActions: [PreparedOfficialDataAction],
        trigger: OfficialDataSyncTrigger,
        startingProviders: [Provider],
        states: [String: OfficialDataActionStoredState]
    ) throws -> MergeActionsResult {
        var providers = startingProviders
        var previews: [OfficialDataPreviewOperation] = []
        var appliedStates: [AppliedState] = []
        var summary = OfficialDataActionSummary.empty
        var didChangeProviders = false
        var seenProviderIDs = Set<UUID>()

        for prepared in preparedActions {
            let bundle = prepared.bundle
            guard prepared.entry.id == bundle.id,
                  prepared.entry.revision == bundle.revision,
                  prepared.entry.kind == bundle.kind.rawValue else {
                throw OfficialDataActionApplyError.metadataMismatch
            }
            guard seenProviderIDs.insert(bundle.provider.id).inserted else {
                throw OfficialDataActionApplyError.duplicateProvider
            }

            let storedState = states[bundle.id]
            if let storedState {
                if bundle.revision < storedState.revision {
                    throw OfficialDataActionApplyError.unsupportedRevision
                }
                if bundle.revision == storedState.revision,
                   prepared.entry.sha256.caseInsensitiveCompare(storedState.payloadSHA256) != .orderedSame {
                    throw OfficialDataActionApplyError.changedRevision
                }
            }

            let localIndex = providers.firstIndex { $0.id == bundle.provider.id }
            let localProvider = localIndex.map { providers[$0] }
            if let storedState,
               bundle.revision == storedState.revision,
               prepared.entry.sha256.caseInsensitiveCompare(storedState.payloadSHA256) == .orderedSame,
               localProvider != nil {
                previews.append(
                    OfficialDataPreviewOperation(
                        id: bundle.id,
                        providerName: bundle.provider.name,
                        providerBaseURL: bundle.provider.baseURL,
                        kind: .unchanged,
                        modelNamesToAdd: [],
                        modelNamesToUpdate: [],
                        modelNamesToRemove: [],
                        changesProviderConfiguration: false,
                        preservesLocalCredentials: true,
                        preservesLocalProxy: true,
                        preservesLocalModelActivation: true,
                        detail: NSLocalizedString(
                            "该版本已应用，本次不会重复修改本地数据。",
                            comment: "Official action already applied"
                        )
                    )
                )
                summary = summary.adding(.skipped)
                continue
            }
            let mergeResult = OfficialProviderThreeWayMerger.merge(
                local: localProvider,
                previousOfficial: storedState?.officialSnapshot,
                incoming: bundle.provider,
                policy: bundle.mergePolicy,
                trigger: trigger,
                actionID: bundle.id
            )
            previews.append(mergeResult.preview)
            summary = summary.adding(mergeResult.outcome)

            if let mergedProvider = mergeResult.provider {
                if let localIndex {
                    if providers[localIndex] != mergedProvider {
                        providers[localIndex] = mergedProvider
                        didChangeProviders = true
                    }
                } else if mergeResult.outcome != .skipped {
                    providers.append(mergedProvider)
                    didChangeProviders = true
                }
            }

            let snapshotData = try ConfigLoader.jsonEncoder.encode(bundle.provider)
            guard let snapshotJSON = String(data: snapshotData, encoding: .utf8) else {
                throw OfficialDataActionApplyError.persistenceUnavailable
            }
            appliedStates.append(
                AppliedState(
                    actionID: bundle.id,
                    revision: bundle.revision,
                    payloadSHA256: prepared.entry.sha256.lowercased(),
                    providerID: bundle.provider.id,
                    snapshotJSON: snapshotJSON
                )
            )
        }

        return MergeActionsResult(
            providers: providers,
            previews: previews,
            appliedStates: appliedStates,
            summary: summary,
            didChangeProviders: didChangeProviders
        )
    }

    private static func loadStates(_ db: Database) throws -> [String: OfficialDataActionStoredState] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT action_id, revision, payload_sha256, provider_id, official_snapshot_json
                FROM official_data_action_state
            """
        )
        var states: [String: OfficialDataActionStoredState] = [:]
        for row in rows {
            let actionID: String = row["action_id"]
            let providerIDRaw: String = row["provider_id"]
            let snapshotJSON: String = row["official_snapshot_json"]
            guard let providerID = UUID(uuidString: providerIDRaw),
                  let data = snapshotJSON.data(using: .utf8),
                  let snapshot = try? ConfigLoader.jsonDecoder.decode(Provider.self, from: data) else {
                continue
            }
            states[actionID] = OfficialDataActionStoredState(
                actionID: actionID,
                revision: row["revision"],
                payloadSHA256: row["payload_sha256"],
                providerID: providerID,
                officialSnapshot: snapshot
            )
        }
        return states
    }
}

enum OfficialProviderThreeWayMerger {
    static func merge(
        local: Provider?,
        previousOfficial: Provider?,
        incoming: Provider,
        policy: OfficialProviderMergePolicy,
        trigger: OfficialDataSyncTrigger,
        actionID: String
    ) -> OfficialProviderMergeResult {
        guard var local else {
            let wasPreviouslyInstalled = previousOfficial != nil
            let shouldRestore: Bool
            switch policy.ifUserDeleted {
            case .keepDeleted:
                shouldRestore = !wasPreviouslyInstalled
            case .restoreOnManualSync:
                shouldRestore = !wasPreviouslyInstalled || trigger == .manualSync
            case .forceRestore:
                shouldRestore = true
            }
            guard shouldRestore else {
                return OfficialProviderMergeResult(
                    provider: nil,
                    outcome: .skipped,
                    preview: makePreview(
                        actionID: actionID,
                        incoming: incoming,
                        kind: .unchanged,
                        addedModels: [],
                        updatedModels: [],
                        removedModels: [],
                        changesProviderConfiguration: false,
                        policy: policy,
                        detail: NSLocalizedString("该提供商已被删除，本次同步会保留删除状态。", comment: "Official provider remains deleted")
                    )
                )
            }
            let outcome: OfficialProviderActionOutcome = wasPreviouslyInstalled ? .restored : .inserted
            return OfficialProviderMergeResult(
                provider: incoming,
                outcome: outcome,
                preview: makePreview(
                    actionID: actionID,
                    incoming: incoming,
                    kind: wasPreviouslyInstalled ? .restore : .insert,
                    addedModels: incoming.models.map(\.displayName),
                    updatedModels: [],
                    removedModels: [],
                    changesProviderConfiguration: true,
                    policy: policy,
                    detail: nil
                )
            )
        }

        let original = local
        local.name = mergeValue(local.name, previousOfficial?.name, incoming.name, policy.providerFields)
        local.baseURL = mergeValue(local.baseURL, previousOfficial?.baseURL, incoming.baseURL, policy.providerFields)
        local.chatEndpointPath = mergeValue(
            local.normalizedChatEndpointPath,
            previousOfficial?.normalizedChatEndpointPath,
            incoming.normalizedChatEndpointPath,
            policy.providerFields
        )
        local.apiFormat = mergeValue(local.apiFormat, previousOfficial?.apiFormat, incoming.apiFormat, policy.providerFields)
        local.apiKeys = mergeAPIKeys(
            local: local.apiKeys,
            previous: previousOfficial?.apiKeys,
            incoming: incoming.apiKeys,
            policy: policy.apiKeys
        )
        local.headerOverrides = mergeDictionary(
            local: local.headerOverrides,
            previous: previousOfficial?.headerOverrides,
            incoming: incoming.headerOverrides,
            policy: policy.headerOverrides
        )
        local.proxyConfiguration = mergeValue(
            local.proxyConfiguration,
            previousOfficial?.proxyConfiguration,
            incoming.proxyConfiguration,
            policy.proxyConfiguration
        )

        let modelMerge = mergeModels(
            local: local.models,
            previous: previousOfficial?.models ?? [],
            incoming: incoming.models,
            policy: policy.models
        )
        local.models = modelMerge.models

        let changed = local != original
        return OfficialProviderMergeResult(
            provider: local,
            outcome: changed ? .updated : .skipped,
            preview: makePreview(
                actionID: actionID,
                incoming: incoming,
                kind: changed ? .update : .unchanged,
                addedModels: modelMerge.added,
                updatedModels: modelMerge.updated,
                removedModels: modelMerge.removed,
                changesProviderConfiguration: providerConfigurationChanged(
                    from: original,
                    to: local
                ),
                policy: policy,
                detail: nil
            )
        )
    }

    private struct ModelMergeResult {
        let models: [Model]
        let added: [String]
        let updated: [String]
        let removed: [String]
    }

    private static func mergeModels(
        local: [Model],
        previous: [Model],
        incoming: [Model],
        policy: OfficialProviderModelMergePolicy
    ) -> ModelMergeResult {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let incomingByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        var result: [Model] = []
        var added: [String] = []
        var updated: [String] = []
        var removed: [String] = []

        for current in local {
            if let next = incomingByID[current.id] {
                let previousModel = previousByID[current.id]
                var merged = mergeModelFields(
                    local: current,
                    previous: previousModel,
                    incoming: next,
                    policy: policy.fields
                )
                merged.isActivated = mergeValue(
                    current.isActivated,
                    previousModel?.isActivated,
                    next.isActivated,
                    policy.isActivated
                )
                result.append(merged)
                if merged != current {
                    updated.append(merged.displayName)
                }
                continue
            }

            if let previousModel = previousByID[current.id] {
                switch policy.onRemoved {
                case .preserve:
                    result.append(current)
                case .deleteIfUnmodified:
                    if current != previousModel {
                        result.append(current)
                    } else {
                        removed.append(current.displayName)
                    }
                }
            } else if policy.userModels == .preserve {
                result.append(current)
            } else {
                removed.append(current.displayName)
            }
        }

        let existingIDs = Set(local.map(\.id))
        if policy.onMissing == .insert {
            for model in incoming where !existingIDs.contains(model.id) {
                result.append(model)
                added.append(model.displayName)
            }
        }
        return ModelMergeResult(models: result, added: added, updated: updated, removed: removed)
    }

    private static func mergeModelFields(
        local: Model,
        previous: Model?,
        incoming: Model,
        policy: OfficialProviderFieldPolicy
    ) -> Model {
        switch policy {
        case .serverWins:
            var result = incoming
            result.isActivated = local.isActivated
            return result
        case .preserveLocal:
            return local
        case .updateIfUnmodified:
            guard let previous else { return local }
            var comparableLocal = local
            comparableLocal.isActivated = false
            var comparablePrevious = previous
            comparablePrevious.isActivated = false
            guard comparableLocal == comparablePrevious else { return local }
            var result = incoming
            result.isActivated = local.isActivated
            return result
        }
    }

    private static func mergeValue<T: Equatable>(
        _ local: T,
        _ previous: T?,
        _ incoming: T,
        _ policy: OfficialProviderFieldPolicy
    ) -> T {
        switch policy {
        case .serverWins:
            return incoming
        case .preserveLocal:
            return local
        case .updateIfUnmodified:
            guard let previous else { return local }
            return local == previous ? incoming : local
        }
    }

    private static func mergeAPIKeys(
        local: [String],
        previous: [String]?,
        incoming: [String],
        policy: OfficialProviderAPIKeyPolicy
    ) -> [String] {
        let normalizedLocal = ProviderCredentialStore.normalizeAPIKeys(local)
        let normalizedIncoming = ProviderCredentialStore.normalizeAPIKeys(incoming)
        switch policy {
        case .preserveLocalIfNonempty:
            return normalizedLocal.isEmpty ? normalizedIncoming : normalizedLocal
        case .serverWins:
            return normalizedIncoming
        case .appendUnique:
            return ProviderCredentialStore.normalizeAPIKeys(normalizedLocal + normalizedIncoming)
        case .updateIfUnmodified:
            guard let previous else { return normalizedLocal }
            let normalizedPrevious = ProviderCredentialStore.normalizeAPIKeys(previous)
            return normalizedLocal == normalizedPrevious ? normalizedIncoming : normalizedLocal
        }
    }

    private static func mergeDictionary(
        local: [String: String],
        previous: [String: String]?,
        incoming: [String: String],
        policy: OfficialProviderDictionaryPolicy
    ) -> [String: String] {
        switch policy {
        case .serverWins:
            return incoming
        case .preserveLocal:
            return local
        case .updateIfUnmodified:
            guard let previous else { return local }
            return local == previous ? incoming : local
        case .mergeServerWins:
            return local.merging(incoming) { _, server in server }
        }
    }

    private static func makePreview(
        actionID: String,
        incoming: Provider,
        kind: OfficialDataPreviewOperationKind,
        addedModels: [String],
        updatedModels: [String],
        removedModels: [String],
        changesProviderConfiguration: Bool,
        policy: OfficialProviderMergePolicy,
        detail: String?
    ) -> OfficialDataPreviewOperation {
        OfficialDataPreviewOperation(
            id: actionID,
            providerName: incoming.name,
            providerBaseURL: incoming.baseURL,
            kind: kind,
            modelNamesToAdd: addedModels,
            modelNamesToUpdate: updatedModels,
            modelNamesToRemove: removedModels,
            changesProviderConfiguration: changesProviderConfiguration,
            preservesLocalCredentials: policy.apiKeys != .serverWins,
            preservesLocalProxy: policy.proxyConfiguration != .serverWins,
            preservesLocalModelActivation: policy.models.isActivated != .serverWins,
            detail: detail
        )
    }

    private static func providerConfigurationChanged(from old: Provider, to new: Provider) -> Bool {
        old.name != new.name ||
            old.baseURL != new.baseURL ||
            old.normalizedChatEndpointPath != new.normalizedChatEndpointPath ||
            old.apiFormat != new.apiFormat ||
            old.apiKeys != new.apiKeys ||
            old.headerOverrides != new.headerOverrides ||
            old.proxyConfiguration != new.proxyConfiguration
    }
}
