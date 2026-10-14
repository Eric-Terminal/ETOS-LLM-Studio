import ETOSCore
import SwiftUI

struct MacOfficialDataPreviewView: View {
    let preview: OfficialDataSyncPreview
    let isActive: Bool
    @ObservedObject private var model = MacAppInformationModel.shared

    var body: some View {
        NavigationStack {
            Form {
                if !preview.preparationFailures.isEmpty {
                    Section(NSLocalizedString("操作失败", comment: "")) {
                        ForEach(preview.preparationFailures, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
                    }
                }
                Section {
                    Text(String(format: NSLocalizedString("将下载 %d 个文件，并处理 %d 个提供商操作。", comment: ""), preview.files.count, preview.operations.count))
                } footer: {
                    Text(NSLocalizedString("只有确认后才会下载文件并修改提供商数据库。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                Section(NSLocalizedString("文件", comment: "")) {
                    ForEach(preview.files) { file in
                        VStack(alignment: .leading) {
                            Text(file.name)
                            Text(file.destinationPath).font(.caption).foregroundStyle(.secondary)
                            Text(String(format: NSLocalizedString("%lld 字节", comment: ""), file.size)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section(NSLocalizedString("提供商操作", comment: "")) {
                    ForEach(preview.operations) { operation in
                        VStack(alignment: .leading) {
                            Text(operation.providerName).font(.headline)
                            Text(title(operation.kind))
                            Text(operation.providerBaseURL).font(.caption).foregroundStyle(.secondary)
                            if operation.changesProviderConfiguration { Text(NSLocalizedString("会更新提供商基础配置。", comment: "")) }
                            modelNames(NSLocalizedString("新增模型", comment: ""), operation.modelNamesToAdd)
                            modelNames(NSLocalizedString("更新模型", comment: ""), operation.modelNamesToUpdate)
                            modelNames(NSLocalizedString("移除模型", comment: ""), operation.modelNamesToRemove)
                            Text(NSLocalizedString(operation.preservesLocalCredentials ? "保留用户修改过的本机 API Key。" : "会按官方配置更新 API Key。", comment: ""))
                            Text(NSLocalizedString(operation.preservesLocalProxy ? "保留用户修改过的本机代理设置。" : "会按官方配置更新代理设置。", comment: ""))
                            Text(NSLocalizedString(operation.preservesLocalModelActivation ? "保留用户设置的模型启用状态。" : "会按官方配置更新模型启用状态。", comment: ""))
                            if let detail = operation.detail { Text(detail).foregroundStyle(.secondary) }
                        }.font(.footnote)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("同步前请确认", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { model.preview = nil }.disabled(model.working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("确认并同步", comment: "")) { if isActive { model.applyOfficialData(preview) } }
                        .disabled(!isActive || model.working || preview.unavailableOperationCount > 0 || !preview.preparationFailures.isEmpty)
                }
            }
            .guideSettingsPageContext(id: "mac-official-data-preview", title: NSLocalizedString("同步前请确认", comment: ""),
                documents: [GuideDocumentReference(id: "mac-app-information", title: NSLocalizedString("同步官方数据", comment: ""))],
                isActive: isActive, settings: [
                    .readOnly("files", label: NSLocalizedString("文件", comment: ""), value: { .int(preview.files.count) }),
                    .readOnly("providers", label: NSLocalizedString("提供商操作", comment: ""), value: { .int(preview.operations.count) }),
                    .readOnly("applying", label: NSLocalizedString("同步官方数据", comment: ""), value: { .bool(model.working) })
                ])
        }
        .frame(minWidth: 560, minHeight: 500)
        .interactiveDismissDisabled(model.working)
        .modifier(MacGuideInspector())
    }

    @ViewBuilder private func modelNames(_ title: String, _ names: [String]) -> some View {
        if !names.isEmpty {
            DisclosureGroup(title) { ForEach(names, id: \.self) { Text($0) } }
        }
    }

    private func title(_ kind: OfficialDataPreviewOperationKind) -> String {
        switch kind {
        case .insert: NSLocalizedString("新增提供商", comment: "")
        case .update: NSLocalizedString("更新提供商", comment: "")
        case .restore: NSLocalizedString("恢复提供商", comment: "")
        case .unchanged: NSLocalizedString("无需修改", comment: "")
        case .unavailable: NSLocalizedString("无法预览", comment: "")
        @unknown default: NSLocalizedString("无法预览", comment: "")
        }
    }
}
