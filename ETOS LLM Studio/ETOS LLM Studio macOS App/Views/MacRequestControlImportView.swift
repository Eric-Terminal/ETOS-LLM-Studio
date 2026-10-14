import ETOSCore
import SwiftUI

struct MacRequestControlImportSource: Identifiable, Sendable {
    let id: String
    let title: String
    let provider: String
    let controls: [ModelRequestBodyControl]
}

struct MacRequestControlImportView: View {
    let modelID: UUID
    let onImport: ([ModelRequestBodyControl]) -> Void
    @State private var sources: [MacRequestControlImportSource] = []
    @State private var busy = false
    @State private var importTask: Task<Void, Never>?
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(sources) { source in
                Button { importControls(source) } label: {
                    VStack(alignment: .leading) {
                        Text(source.title)
                        Text(source.provider).font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.borderless)
            }
            .disabled(busy || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("从其他模型导入", comment: ""))
            .overlay { if sources.isEmpty { Text(NSLocalizedString("没有可导入的控制项。", comment: "")).foregroundStyle(.secondary) } }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } } }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-request-body-\(modelID)-import"), title: NSLocalizedString("从其他模型导入", comment: ""),
                documents: [GuideDocumentReference(id: "model-request-body", title: "Request Body Controls")], settings: [
                    .readOnly("source_count", label: NSLocalizedString("模型", comment: ""), value: { .int(sources.count) }),
                    .readOnly("read_only", label: NSLocalizedString("应用方式", comment: ""), value: { .bool(true) })
                ])
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 480, minHeight: 400)
        .task {
            let providers = workspace.providers, excluded = modelID
            let prepared = await Task.detached {
                providers.flatMap { provider in
                    provider.models.filter { $0.id != excluded && !$0.requestBodyControls.isEmpty }.map {
                        MacRequestControlImportSource(id: "\(provider.id)-\($0.id)", title: $0.displayName,
                                                      provider: provider.name, controls: $0.requestBodyControls)
                    }
                }
            }.value
            guard !Task.isCancelled else { return }
            sources = prepared
        }
        .onDisappear { importTask?.cancel() }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
    }

    private func importControls(_ source: MacRequestControlImportSource) {
        guard !busy, !workspace.isRestoringData else { return }
        busy = true
        importTask = Task {
            let controls = await Task.detached { source.controls.map { $0.duplicatedWithNewIdentifiers() } }.value
            guard !Task.isCancelled, !workspace.isRestoringData else { return }
            onImport(controls)
            dismiss()
        }
    }
}
