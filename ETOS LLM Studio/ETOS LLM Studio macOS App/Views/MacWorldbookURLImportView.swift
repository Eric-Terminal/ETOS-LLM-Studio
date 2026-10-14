import ETOSCore
import SwiftUI

struct MacWorldbookURLImportView: View {
    @ObservedObject var model: MacWorldbookModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var address = ""
    @State private var importTask: Task<Void, Never>?
    @State private var isImporting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("世界书链接", comment: ""), text: $address).disabled(isImporting)
                } footer: {
                    Text(NSLocalizedString("支持 http/https 链接，下载后自动识别 JSON 或 PNG。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if isImporting {
                    if let progress = model.downloadProgress, progress.totalBytes > 0 {
                        ProgressView(value: progress.fractionCompleted)
                    } else { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("从 URL 导入世界书", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) {
                        if isImporting { importTask?.cancel() } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("导入", comment: "")) { start() }
                        .disabled(address.isEmpty || isImporting || model.isWorking || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(
                id: "mac-worldbook-url-import", title: NSLocalizedString("从 URL 导入世界书", comment: ""),
                documents: [GuideDocumentReference(id: "worldbooks", title: "Worldbooks"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                settings: [
                    .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(isImporting) }),
                    .readOnly("manual_submission", label: NSLocalizedString("导入", comment: ""), value: { .bool(true) })
                ] + (isImporting || workspace.isRestoringData ? [] : [
                    .writeOnlyString("url", label: NSLocalizedString("世界书链接", comment: ""), isConfigured: { !address.isEmpty }, set: { address = $0 })
                ])
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(isImporting)
        .frame(minWidth: 460, minHeight: 260)
    }

    private func start() {
        guard !isImporting else { return }
        isImporting = true
        error = nil
        let address = address
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            do { try await model.importURL(address); dismiss() }
            catch is CancellationError { dismiss() }
            catch {
                if Task.isCancelled { dismiss() }
                else { self.error = error.localizedDescription }
            }
        }
    }
}
