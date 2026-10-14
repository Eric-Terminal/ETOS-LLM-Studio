import ETOSCore
import Combine
import SwiftUI

struct MacModelConnectivityTestView: View {
    @StateObject private var model: MacModelConnectivityModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLock = AppLockManager.shared
    @ObservedObject private var config = AppConfigStore.shared

    init(source: MacModelConnectivitySource) {
        _model = StateObject(wrappedValue: MacModelConnectivityModel(source: source))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.source.provider.name)
                    if let selected = model.source.model {
                        Text(selected.displayName)
                        Text(selected.modelName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(String(format: NSLocalizedString("%d / %d 已完成", comment: ""), model.completed, model.total))
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.completed > 0 { Text(model.summary).font(.footnote).foregroundStyle(.secondary) }
                    if model.isRunning {
                        ProgressView(model.isCancelling ? NSLocalizedString("正在取消测试…", comment: "") : NSLocalizedString("测试中", comment: ""))
                    }
                    MacSettingsIntroCard(id: "model-test-\(model.source.id)", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 模型连通性检查使用说明", comment: ""), documentID: "provider-model-basics")
                } footer: {
                    Text(NSLocalizedString("测试会使用当前草稿发送真实请求，可能产生费用；配置不会自动保存。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if model.source.model == nil {
                    Section {
                        TextField(NSLocalizedString("并发数量", comment: ""), text: Binding(get: { model.concurrencyText }, set: { model.setConcurrency($0) }))
                            .disabled(model.isRunning || model.isPreparing || model.isValidatingSource || model.invalidated || !workspace.canRunModelTests)
                        if !model.concurrencyIsValid {
                            Text(NSLocalizedString("并发数量须为正整数。", comment: "")).font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
                Section {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading) {
                            HStack {
                                Text(row.title)
                                Spacer()
                                Label(row.status.localizedName, systemImage: statusSymbol(row.status))
                                    .font(.caption).foregroundStyle(row.status == .failed ? .red : .secondary)
                            }
                            if let subtitle = row.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if let latency = row.latency { Text(latency).font(.caption).foregroundStyle(.secondary) }
                            if let preview = row.preview { Text(preview).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if let error = row.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        }
                    }
                    if !model.isPreparing, model.total == 0 {
                        Text(NSLocalizedString("没有可测试的已添加模型。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text(NSLocalizedString("测试结果", comment: "")) }
            }
            .navigationTitle(NSLocalizedString("模型测试", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("关闭", comment: "")) { dismiss() } }
                ToolbarItem {
                    if model.isRunning {
                        Button(NSLocalizedString("取消测试", comment: "")) { model.cancel() }.disabled(model.isCancelling)
                    } else {
                        Button(model.completed > 0 ? NSLocalizedString("重新测试", comment: "") : NSLocalizedString("开始测试", comment: "")) {
                            guard workspace.canRunModelTests else { return }
                            model.start()
                        }.disabled(!model.canStart || !workspace.canRunModelTests)
                    }
                }
            }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-model-test-\(model.source.id)"), title: NSLocalizedString("模型测试", comment: ""),
                documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")], settings: guideSettings)
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 580, minHeight: 520)
        .task {
            guard workspace.canRunModelTests, let service = workspace.service else { dismiss(); return }
            workspace.modelTests.register(model)
            await model.prepare(service: service, providers: workspace.$providers.eraseToAnyPublisher())
        }
        .onDisappear { workspace.modelTests.detach(model) }
        .onChange(of: model.invalidated) { _, invalidated in if invalidated { dismiss() } }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { model.invalidate(); dismiss() } }
        .onChange(of: appLock.state) { _, state in if state == .locked { model.invalidate(); dismiss() } }
        .onChange(of: config.appLanguage) { _, _ in model.refreshLanguage() }
    }

    private var guideSettings: [GuidePageSetting] {
        let state: [GuidePageSetting] = [
            .readOnly("source", label: NSLocalizedString("应用方式", comment: ""), value: { .string("unsaved_provider_and_model_draft") }),
            .readOnly("running", label: NSLocalizedString("测试中", comment: ""), value: { .bool(model.isRunning) }),
            .readOnly("completed", label: NSLocalizedString("测试结果", comment: ""), value: { .int(model.completed) }),
            .readOnly("total", label: NSLocalizedString("模型", comment: ""), value: { .int(model.total) })
        ]
        guard model.source.model == nil, !model.isRunning, !model.invalidated, !model.isPreparing, !model.isValidatingSource, workspace.canRunModelTests else { return state }
        return state + [.integer("concurrency", label: NSLocalizedString("并发数量", comment: ""), range: 1...Int.max,
            get: { Int(model.concurrencyText) ?? 1 }, set: { model.setConcurrency(String($0)) })]
    }

    private func statusSymbol(_ status: ModelConnectivityTestResult.Status) -> String {
        switch status {
        case .pending: "circle"
        case .testing: "ellipsis.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}
