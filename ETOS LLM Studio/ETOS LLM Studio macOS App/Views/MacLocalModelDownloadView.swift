import ETOSCore
import SwiftUI

struct MacLocalModelDownloadView: View {
    let isActive: Bool
    @ObservedObject var library: MacLocalModelLibraryModel
    @ObservedObject private var download: MacLocalModelDownload
    @ObservedObject private var configuration = AppConfigStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var displayName = ""
    @State private var operationID: UUID?
    @State private var pageID = UUID()
    @State private var isVisible = false
    @State private var epoch: UUID

    init(library: MacLocalModelLibraryModel, isActive: Bool) {
        self.library = library; self.isActive = isActive
        _download = ObservedObject(wrappedValue: library.download)
        _epoch = State(initialValue: library.epoch)
    }

    private var isCurrent: Bool { isActive && isVisible && epoch == library.epoch && !library.isSuspended }
    private var phase: MacLocalModelDownload.Phase { operationID == download.id ? download.phase : .idle }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "mac-local-download", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac 本地模型下载使用说明", comment: ""), documentID: "local-models")
                    TextField(NSLocalizedString("模型文件链接", comment: ""), text: $urlText)
                    TextField(NSLocalizedString("名称", comment: ""), text: $displayName)
                }
                .disabled(phase.isWorking || !library.canWrite)
                Section {
                    if phase.isWorking {
                        if phase == .downloading, let progress = download.progress, progress.raw.totalBytes > 0 {
                            ProgressView(value: progress.raw.fractionCompleted) {
                                Text(NSLocalizedString("下载进度", comment: ""))
                            }
                        } else {
                            ProgressView(status)
                        }
                        if let progress = download.progress {
                            Text(progress.caption).font(.caption).foregroundStyle(.secondary)
                        }
                        Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                            if let operationID { download.cancel(operationID) }
                        }.disabled(phase != .downloading)
                    } else {
                        if phase != .idle { Text(status).font(.footnote).foregroundStyle(.secondary) }
                        if phase == .failed, let error = download.error {
                            Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Button(NSLocalizedString("下载权重", comment: "")) {
                            guard isCurrent else { return }
                            operationID = library.startDownload(urlText: urlText, displayName: displayName, expectedEpoch: epoch)
                        }.disabled(!library.canWrite || urlText.isEmpty)
                    }
                } footer: {
                    Text(NSLocalizedString("关闭下载页会取消尚未保存的下载。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(!isCurrent)
            .navigationTitle(NSLocalizedString("下载权重", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "")) {
                        if let operationID { download.cancel(operationID) }
                        dismiss()
                    }
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-local-download-\(pageID)"), title: NSLocalizedString("下载权重", comment: ""),
                documents: [GuideDocumentReference(id: "local-models", title: "Local Models")],
                isActive: isCurrent, settings: guideSettings
            )
        }
        .frame(minWidth: 500, minHeight: 350)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; if let operationID { download.cancel(operationID) } }
        .onChange(of: isActive) { _, active in
            if !active, let operationID { download.cancel(operationID) }
        }
        .onChange(of: download.phase) { _, value in
            if operationID == download.id, value == .completed { urlText = ""; displayName = "" }
        }
        .onChange(of: configuration.appLanguage) { _, _ in download.refreshProgress() }
    }

    private var status: String {
        switch phase {
        case .idle, .downloading: return NSLocalizedString("下载进度", comment: "")
        case .saving: return NSLocalizedString("保存中", comment: "")
        case .cancelling: return NSLocalizedString("取消中", comment: "")
        case .completed: return NSLocalizedString("下载完成。", comment: "")
        case .cancelled: return NSLocalizedString("已取消", comment: "")
        case .failed: return NSLocalizedString("下载失败", comment: "")
        }
    }

    private var guideSettings: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .readOnly("status", label: NSLocalizedString("下载进度", comment: ""), value: { .string(phase.rawValue) }),
            .readOnly("requires_download", label: NSLocalizedString("填写后需要点击下载权重", comment: ""), value: { .bool(true) })
        ]
        if !phase.isWorking && library.canWrite {
            // 临时签名链接可能携带令牌，不向模型暴露用户已经填写的内容。
            fields += [
                .writeOnlyString("download_url", label: NSLocalizedString("模型文件链接", comment: ""),
                                 isConfigured: { !urlText.isEmpty }, set: { urlText = $0 }),
                .string("display_name", label: NSLocalizedString("名称", comment: ""), get: { displayName }, set: { displayName = $0 })
            ]
        }
        return fields
    }
}
