import ETOSCore
import SwiftUI

@MainActor
struct MacStorageFilePreviewView: View {
    let file: MacStorageFile
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacStorageReadModel<MacStorageFilePreview>()
    @State private var pageIndex = 0
    @State private var visible = false
    private var active: Bool { visible && isActive && workspace.canManageLocalModels }
    private var page: StorageTextPage? {
        guard let pages = model.value?.pages, pages.indices.contains(pageIndex) else { return nil }
        return pages[pageIndex]
    }

    var body: some View {
        VStack {
            if model.isLoading { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
            if let image = model.value?.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding().accessibilityLabel(file.item.name)
            } else if let page {
                ScrollView([.horizontal, .vertical]) {
                    Text(page.content).font(.body.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                HStack {
                    Button(NSLocalizedString("上一页", comment: "")) { pageIndex -= 1 }.disabled(pageIndex == 0)
                    Text(String(format: NSLocalizedString("第 %d / %d 页", comment: ""), pageIndex + 1, model.value?.pages.count ?? 0))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(NSLocalizedString("下一页", comment: "")) { pageIndex += 1 }.disabled(pageIndex + 1 >= (model.value?.pages.count ?? 0))
                }.padding()
            }
            if let error = model.error ?? model.value?.error { Text(error).font(.footnote).foregroundStyle(.secondary).padding() }
        }
        .navigationTitle(file.item.name).disabled(!active)
        .toolbar { Button(NSLocalizedString("关闭", comment: "")) { dismiss() } }
        .onAppear { visible = true }
        .onDisappear { visible = false; model.close() }
        .onChange(of: active) { _, value in if value { reload() } else { model.close() } }
        .onChange(of: configuration.appLanguage) { _, _ in reload() }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-storage-preview-\(model.revision)"), title: NSLocalizedString("文件预览", comment: ""),
            documents: [GuideDocumentReference(id: "storage-management", title: "Storage Management")], isActive: active, settings: [
                .readOnly("image", label: NSLocalizedString("图片", comment: ""), value: { .bool(file.isImage) }),
                .readOnly("file_bytes", label: NSLocalizedString("文件大小", comment: ""), value: { .int(Int(clamping: file.item.size)) }),
                .readOnly("line_count", label: NSLocalizedString("总行数", comment: ""), value: { .int(model.value?.lineCount ?? 0) }),
                .readOnly("page", label: NSLocalizedString("文件预览", comment: ""), value: { .int(pageIndex + 1) })
            ])
    }
    private func reload() {
        guard active else { return }; pageIndex = 0
        let file = file
        model.load(workspace: workspace) { try MacStorageFilePreview.load(file) }
    }
}
