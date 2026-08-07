import SwiftUI
import ETOSCore

struct OfficialDataSyncPreviewView: View {
    let preview: OfficialDataSyncPreview
    let isApplying: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "将下载 %d 个文件，并处理 %d 个提供商操作。",
                                comment: "官方数据同步预览摘要"
                            ),
                            preview.files.count,
                            preview.operations.count
                        )
                    )
                } footer: {
                    Text(NSLocalizedString("只有确认后才会下载文件并修改提供商数据库。", comment: "官方数据确认说明"))
                }

                if !preview.files.isEmpty {
                    Section(NSLocalizedString("文件", comment: "官方同步文件分组")) {
                        ForEach(preview.files) { file in
                            VStack(alignment: .leading) {
                                Text(file.name)
                                Text(file.fileName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(
                                    String(
                                        format: NSLocalizedString("目标：%@", comment: "官方同步文件目标"),
                                        file.destinationPath
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Text(
                                    String(
                                        format: NSLocalizedString("%lld 字节", comment: "官方同步文件大小"),
                                        file.size
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !preview.operations.isEmpty {
                    Section(NSLocalizedString("提供商操作", comment: "官方同步数据库操作分组")) {
                        ForEach(preview.operations) { operation in
                            operationRow(operation)
                        }
                    }
                }

                if preview.isEmpty {
                    Section {
                        Text(NSLocalizedString("没有需要下载或修改的官方数据。", comment: "官方同步空预览"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("同步前请确认", comment: "官方同步预览标题"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "取消官方同步"), action: onCancel)
                        .disabled(isApplying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onConfirm) {
                        if isApplying {
                            ProgressView()
                        } else {
                            Text(NSLocalizedString("确认并同步", comment: "确认官方同步"))
                        }
                    }
                    .disabled(isApplying || preview.unavailableOperationCount > 0)
                }
            }
            .interactiveDismissDisabled(isApplying)
        }
    }

    @ViewBuilder
    private func operationRow(_ operation: OfficialDataPreviewOperation) -> some View {
        VStack(alignment: .leading) {
            Label(operationTitle(operation.kind), systemImage: operationIcon(operation.kind))
            Text(operation.providerName)
                .font(.subheadline)
            if !operation.providerBaseURL.isEmpty {
                Text(operation.providerBaseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if operation.changesProviderConfiguration {
                detailLine(NSLocalizedString("会更新提供商基础配置。", comment: "官方同步提供商配置变化"))
            }
            modelLines(NSLocalizedString("新增模型", comment: "官方同步新增模型"), operation.modelNamesToAdd)
            modelLines(NSLocalizedString("更新模型", comment: "官方同步更新模型"), operation.modelNamesToUpdate)
            modelLines(NSLocalizedString("移除模型", comment: "官方同步移除模型"), operation.modelNamesToRemove)
            if operation.preservesLocalCredentials {
                detailLine(NSLocalizedString("保留用户修改过的本机 API Key。", comment: "官方同步保留密钥"))
            } else {
                detailLine(NSLocalizedString("会按官方配置更新 API Key。", comment: "官方同步更新密钥"))
            }
            if operation.preservesLocalProxy {
                detailLine(NSLocalizedString("保留用户修改过的本机代理设置。", comment: "官方同步保留代理"))
            } else {
                detailLine(NSLocalizedString("会按官方配置更新代理设置。", comment: "官方同步更新代理"))
            }
            if operation.preservesLocalModelActivation {
                detailLine(NSLocalizedString("保留用户设置的模型启用状态。", comment: "官方同步保留模型启用状态"))
            } else {
                detailLine(NSLocalizedString("会按官方配置更新模型启用状态。", comment: "官方同步更新模型启用状态"))
            }
            if let detail = operation.detail {
                detailLine(detail)
            }
        }
    }

    private func modelLines(_ title: String, _ names: [String]) -> some View {
        Group {
            if !names.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(names, id: \.self) { name in
                    Text(verbatim: "• \(name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func operationTitle(_ kind: OfficialDataPreviewOperationKind) -> String {
        switch kind {
        case .insert: NSLocalizedString("新增提供商", comment: "官方同步新增提供商")
        case .update: NSLocalizedString("更新提供商", comment: "官方同步更新提供商")
        case .restore: NSLocalizedString("恢复提供商", comment: "官方同步恢复提供商")
        case .unchanged: NSLocalizedString("无需修改", comment: "官方同步无变化")
        case .unavailable: NSLocalizedString("无法预览", comment: "官方同步操作不可用")
        }
    }

    private func operationIcon(_ kind: OfficialDataPreviewOperationKind) -> String {
        switch kind {
        case .insert: "plus.circle"
        case .update: "arrow.triangle.2.circlepath"
        case .restore: "arrow.uturn.backward.circle"
        case .unchanged: "checkmark.circle"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}
