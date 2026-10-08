import ETOSCore
import SwiftUI

@MainActor
struct MacDataImportView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @StateObject private var model = MacDataImportModel()
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels }
    static let documents = [GuideDocumentReference(id: "data-import", title: "Data Import")]

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "data-import", title: NSLocalizedString("导入数据", comment: ""),
                    details: NSLocalizedString("Mac 数据导入说明正文", comment: ""), documentID: "data-import", isActive: available)
                Picker(NSLocalizedString("导入来源", comment: ""), selection: Binding(get: { model.source }, set: model.changeSource)) {
                    ForEach(ThirdPartyImportSource.allCases, id: \.rawValue) { source in Text(source.displayName).tag(source) }
                }.disabled(!model.canEdit)
            } footer: {
                Text(MacDataImportModel.sourceHint(model.source)).font(.footnote).foregroundStyle(.secondary)
            }
            Section(NSLocalizedString("导入操作", comment: "")) {
                Button(action: model.chooseFiles) {
                    Label(NSLocalizedString("选择文件并解析", comment: ""), systemImage: "doc.text.magnifyingglass")
                }.disabled(!model.canEdit)
                if !model.fileName.isEmpty {
                    LabeledContent(NSLocalizedString("最近选择", comment: ""), value: model.fileName)
                }
                if model.isPreparing {
                    ProgressView(NSLocalizedString("正在解析备份内容...", comment: ""))
                    Button(NSLocalizedString("取消", comment: ""), action: model.cancelPreparation)
                }
                if model.isImporting { ProgressView(NSLocalizedString("正在导入并合并数据...", comment: "")) }
            }
            if let preview = model.preview {
                Section(NSLocalizedString("解析预览", comment: "")) {
                    ForEach(preview.rows) { row in LabeledContent(row.title, value: row.value) }
                }
                Section {
                    if let scope = preview.fixedScope {
                        LabeledContent(NSLocalizedString("导出同步项", comment: ""), value: scope)
                        Text(NSLocalizedString("ETOS 数据包会按导出时勾选的同步项执行全量导入。", comment: ""))
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(preview.scopeRows) { category in
                            Toggle(category.title, isOn: Binding(get: { model.selected.contains(category) },
                                set: { model.setSelected(category, enabled: $0) }))
                                .disabled(!model.canEdit)
                        }
                    }
                    Button(NSLocalizedString("确认导入", comment: ""), action: model.requestConfirmation)
                        .disabled(!model.canImport)
                } header: { Text(NSLocalizedString("导入范围", comment: "")) }
                footer: {
                    Text(NSLocalizedString("冲突预览为本地启发式估算，最终结果以导入完成后的统计为准。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !preview.skillNames.isEmpty {
                    Section(NSLocalizedString("Agent Skills", comment: "")) {
                        ForEach(preview.skillNames) { row in Text(row.title).textSelection(.enabled) }
                    }
                }
                if !preview.warnings.isEmpty {
                    Section(NSLocalizedString("解析提示", comment: "")) {
                        ForEach(preview.warnings) { row in Text(row.title).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            if let report = model.report {
                Section(NSLocalizedString("最近导入结果", comment: "")) {
                    ForEach(report.rows) { row in LabeledContent(row.title, value: row.value) }
                }
                if !report.warnings.isEmpty {
                    Section(NSLocalizedString("导入提示", comment: "")) {
                        ForEach(report.warnings) { row in Text(row.title).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            if let error = model.error {
                Section(NSLocalizedString("导入错误", comment: "")) { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("导入数据", comment: ""))
        .onAppear { visible = true; updateActivity() }
        .onDisappear { visible = false; updateActivity() }
        .onChange(of: available) { _, _ in updateActivity(discard: !available) }
        .onChange(of: appLock.state) { _, value in if value == .locked { updateActivity(discard: true) } }
        .onChange(of: configuration.appLanguage) { _, language in
            AppLanguageRuntime.apply(rawValue: language); model.languageChanged()
        }
        .sheet(item: $model.confirmation) { confirmation in
            MacDataImportConfirmationView(model: model, confirmation: confirmation)
        }
        .sheet(item: $model.snapshotFile) { file in
            MacSnapshotRestoreSheet(file: file) { model.snapshotFile = nil }
        }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-data-import-\(model.revision)"),
            title: NSLocalizedString("导入数据", comment: ""), documents: Self.documents,
            isActive: available && visible && !model.isPreparing && !model.isPanelOpen && !model.isImporting
                && model.confirmation == nil && model.snapshotFile == nil,
            settings: guideSettings)
    }

    private func updateActivity(discard: Bool = false) {
        model.setActive(visible && available, workspace: workspace, discardPreview: discard)
    }

    private var guideSettings: [GuidePageSetting] {
        var settings: [GuidePageSetting] = [
            .string("source", label: NSLocalizedString("导入来源", comment: ""),
                allowedValues: ThirdPartyImportSource.allCases.map(\.rawValue), get: { model.source.rawValue },
                set: { if let source = ThirdPartyImportSource(rawValue: $0) { model.changeSource(source) } }),
            .readOnly("save_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("draft_requires_native_import_confirmation") }),
            .readOnly("preview", label: NSLocalizedString("解析预览", comment: ""), value: { model.preview?.guideCounts ?? .null }),
            .readOnly("fixed_scope", label: NSLocalizedString("导出同步项", comment: ""), value: { .string(model.preview?.fixedScope ?? "") }),
            .readOnly("requires_credentials_confirmation", label: NSLocalizedString("我确认导入其中的敏感凭据", comment: ""), value: { .bool(model.requiresCredentials) }),
            .readOnly("report", label: NSLocalizedString("最近导入结果", comment: ""), value: { model.report?.guideSummary ?? .null })
        ]
        if let preview = model.preview, preview.fixedScope == nil {
            // 可编辑目录固定最多四项，与文件中的记录数量无关。
            for category in preview.scopeRows {
                settings.append(.bool(category.rawValue, label: category.title, get: { model.selected.contains(category) },
                    set: { model.setSelected(category, enabled: $0) }))
            }
        }
        return settings
    }
}

@MainActor
private struct MacDataImportConfirmationView: View {
    @ObservedObject var model: MacDataImportModel
    let confirmation: MacDataImportConfirmation
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: MacWorkspaceModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(NSLocalizedString("导入来源", comment: ""), value: confirmation.source)
                    LabeledContent(NSLocalizedString("导入范围", comment: ""), value: confirmation.scope)
                    Text(NSLocalizedString("Mac 数据合并确认说明", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if confirmation.requiresCredentials {
                    Section {
                        Text(NSLocalizedString("所选配置可能包含 API Key、令牌或其他凭据。", comment: ""))
                            .font(.footnote).foregroundStyle(.secondary)
                        Toggle(NSLocalizedString("我确认导入其中的敏感凭据", comment: ""), isOn: $model.credentialsAcknowledged)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("确认导入", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("确认导入", comment: "")) { model.confirmImport(confirmation) }
                        .disabled(!model.canConfirm || model.revision != confirmation.id)
                }
            }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-data-import-confirmation-\(confirmation.id)"),
                title: NSLocalizedString("确认导入", comment: ""), documents: MacDataImportView.documents,
                isActive: workspace.canManageLocalModels && model.confirmation?.id == confirmation.id,
                settings: [
                    .readOnly("source", label: NSLocalizedString("导入来源", comment: ""), value: { .string(confirmation.source) }),
                    .readOnly("scope", label: NSLocalizedString("导入范围", comment: ""), value: { .string(confirmation.scope) }),
                    .readOnly("requires_credentials_confirmation", label: NSLocalizedString("我确认导入其中的敏感凭据", comment: ""), value: { .bool(confirmation.requiresCredentials) }),
                    .readOnly("native_confirmation_required", label: NSLocalizedString("确认导入", comment: ""), value: { .bool(true) })
                ])
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 560, minHeight: 400)
    }
}
