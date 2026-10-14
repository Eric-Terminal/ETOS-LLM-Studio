import ETOSCore
import SwiftUI

@MainActor
struct MacImageGalleryView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @StateObject private var model = MacImageGalleryModel()
    @State private var preview: MacImageGalleryItem?
    @State private var pendingDeletion: MacImageGalleryItem?
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                MacSettingsIntroCard(id: "image-gallery", title: NSLocalizedString("图片相册", comment: ""),
                    details: NSLocalizedString("Mac 图片相册使用说明", value: "Browse images returned by the assistant in the current conversation. Select an image to preview it or save the original file to a folder. Deletion requires confirmation and removes its message attachment; files still referenced by other messages are retained.", comment: ""),
                    documentID: "mac-image-gallery", isActive: available)
                if model.items.isEmpty {
                    Text(NSLocalizedString("当前会话暂无助手返回的图片。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))]) {
                    ForEach(model.items) { item in
                        VStack(alignment: .leading) {
                            Button { preview = item } label: { MacAttachmentImage(url: item.url) }
                                .buttonStyle(.plain)
                            Text(item.sourcePrompt.isEmpty ? NSLocalizedString("助手图片", comment: "") : item.sourcePrompt)
                                .font(.footnote).lineLimit(2)
                            Text(item.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            HStack {
                                Button(NSLocalizedString("导出", comment: "")) { model.export(item) }.disabled(model.exporting)
                                Button(NSLocalizedString("删除", comment: ""), role: .destructive) { pendingDeletion = item }
                                    .disabled(!workspace.canModifyCurrentHistory)
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }.padding()
        }
        .navigationTitle(NSLocalizedString("图片相册", comment: ""))
        .disabled(!available)
        .onAppear { visible = true; reload() }
        .onDisappear { visible = false; model.clear() }
        .onReceive(workspace.$messages) { _ in if visible { reload() } }
        .onChange(of: workspace.currentSession?.id) { _, _ in reset(); reload() }
        .onChange(of: available) { _, active in if active { reload() } else { reset() } }
        .sheet(item: $preview) { item in
            VStack {
                ScrollView {
                    MacAttachmentImage(url: item.url, maximumHeight: 720)
                    Text(item.sourcePrompt).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button(NSLocalizedString("完成", comment: "")) { preview = nil }
            }
            .padding().frame(minWidth: 500, minHeight: 400)
            .guideSettingsPageContext(id: "mac-image-preview", title: NSLocalizedString("图片相册", comment: ""),
                documents: [GuideDocumentReference(id: "mac-image-gallery", title: NSLocalizedString("图片相册", comment: ""))],
                isActive: available, settings: [
                    .readOnly("read_only", label: NSLocalizedString("预览", comment: ""), value: { .bool(true) })
                ])
            .modifier(MacGuideInspector())
        }
        .confirmationDialog(NSLocalizedString("确认删除这张图片？", comment: ""),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    guard let item = pendingDeletion else { return }
                    pendingDeletion = nil
                    remove(item)
                }
            }
        .guideSettingsPageContext(id: "mac-image-gallery", title: NSLocalizedString("图片相册", comment: ""),
            documents: [GuideDocumentReference(id: "mac-image-gallery", title: NSLocalizedString("图片相册", comment: ""))],
            isActive: available && visible && preview == nil, settings: [
                .readOnly("image_count", label: NSLocalizedString("图片相册", comment: ""), value: { .int(model.items.count) }),
                .readOnly("exporting", label: NSLocalizedString("导出", comment: ""), value: { .bool(model.exporting) })
            ])
    }

    private func reload() {
        guard available, let service = workspace.service, let sessionID = workspace.currentSession?.id else { model.clear(); return }
        model.reload(service: service, sessionID: sessionID)
    }

    private func reset() { preview = nil; pendingDeletion = nil; model.clear() }

    private func remove(_ item: MacImageGalleryItem) {
        guard available, workspace.canModifyCurrentHistory, workspace.currentSession?.id == item.sessionID else { return }
        Task {
            let edited = await Task.detached(priority: .userInitiated) { item.removingImage() }.value
            guard available, workspace.currentSession?.id == item.sessionID else { return }
            if let edited {
                do { try await workspace.updateMessage(edited, original: item.message, sessionID: item.sessionID) }
                catch { model.error = error.localizedDescription }
            } else {
                workspace.deleteMessage(.init(message: item.message, sessionID: item.sessionID, kind: .message))
            }
        }
    }
}
