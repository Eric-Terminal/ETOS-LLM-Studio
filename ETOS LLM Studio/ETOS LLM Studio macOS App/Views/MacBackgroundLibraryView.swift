import ETOSCore
import PhotosUI
import SwiftUI

struct MacBackgroundLibraryView: View {
    @ObservedObject var model: MacBackgroundModel
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var visible = false
    @State private var deleting: Deletion?
    @State private var photoRequest: PhotoRequest?
    private struct Deletion { let file: MacBackgroundFile; let epoch: UUID }
    private struct PhotoRequest { let id = UUID(); let epoch: UUID }
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended }
    private var active: Bool { available && visible && model.canEdit && deleting == nil }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "background-library", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 背景使用说明", comment: ""), documentID: "settings-display", isActive: available)
                Button { model.openImportPanel() } label: { Label(NSLocalizedString("导入背景", comment: ""), systemImage: "plus") }
                    .disabled(!model.canEdit)
                Button {
                    photoRequest = PhotoRequest(epoch: model.epoch)
                    model.setPhotoPickerPresented(true)
                } label: { Label(NSLocalizedString("从照片图库导入", comment: ""), systemImage: "photo.on.rectangle") }
                    .disabled(!model.canEdit)
                Button(NSLocalizedString("刷新", comment: "")) { model.reload() }
                    .disabled(model.isWorking || model.isLoading || model.isPresentingMedia)
            }
            if model.isLoading || model.isWorking { ProgressView() }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            Section {
                ForEach(model.catalog.files) { file in
                    HStack {
                        MacBackgroundThumbnail(file: file)
                        Button { model.select(file.id, expectedEpoch: model.epoch) } label: {
                            Label(file.id, systemImage: model.selectedFile?.id == file.id ? "checkmark.circle.fill" : (file.isVideo ? "video" : "photo"))
                        }
                        .disabled(!model.canEdit)
                        Spacer()
                        if !file.isVideo {
                            Button { model.beginCrop(file, expectedEpoch: model.epoch) } label: {
                                Label(NSLocalizedString("裁切", comment: ""), systemImage: "crop")
                            }
                            .disabled(!model.canEdit)
                        }
                        Button(role: .destructive) { deleting = Deletion(file: file, epoch: model.epoch) } label: {
                            Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                        }
                        .disabled(!model.canEdit)
                    }
                    .buttonStyle(.borderless)
                }
                if model.catalog.files.isEmpty, !model.isLoading {
                    Text(NSLocalizedString("暂无背景，请先导入图片或视频。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("选择背景", comment: ""))
        .disabled(!available)
        .onAppear { visible = true; model.reload() }
        .onDisappear { visible = false; deleting = nil; photoRequest = nil; model.setPhotoPickerPresented(false); model.cancelImportPanel(); model.cancelCrop() }
        .onChange(of: available) { _, available in
            if !available { deleting = nil; photoRequest = nil; model.setPhotoPickerPresented(false); model.cancelImportPanel(); model.cancelCrop() }
        }
        .onChange(of: model.epoch) { _, _ in deleting = nil; photoRequest = nil }
        .photosPicker(isPresented: photoPresentation, selection: photoSelection, matching: .any(of: [.images, .videos]))
        .sheet(item: cropPresentation) { draft in
            MacBackgroundCropEditor(model: model, draft: draft, isActive: available)
        }
        .alert(NSLocalizedString("删除背景", comment: ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard let target = deleting, available else { return }
                deleting = nil; model.delete(target.file, expectedEpoch: target.epoch)
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { deleting = nil }
        } message: { Text(NSLocalizedString("确定删除这张背景吗？", comment: "")) }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-background-library-\(model.epoch)"), title: NSLocalizedString("选择背景", comment: ""),
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")], isActive: active,
            settings: guideSettings
        )
    }

    private var photoPresentation: Binding<Bool> {
        let id = photoRequest?.id
        return Binding(get: { model.isPhotoPickerOpen }, set: { value in
            guard photoRequest?.id == id else { return }
            model.setPhotoPickerPresented(value)
        })
    }

    private var cropPresentation: Binding<MacBackgroundCropDraft?> {
        let id = model.cropDraft?.id
        return Binding(get: { model.cropDraft }, set: { value in
            if value == nil, let id { model.cancelCrop(id: id) }
        })
    }

    private var photoSelection: Binding<PhotosPickerItem?> {
        let request = photoRequest
        return Binding(get: { nil }, set: { item in
            // 固定每次系统选择器的来源，关闭页面或重新打开后不接收旧回调。
            guard let item, let request, photoRequest?.id == request.id,
                  available, visible, request.epoch == model.epoch else { return }
            photoRequest = nil
            model.importPhoto(item, expectedEpoch: request.epoch)
        })
    }

    private var guideSettings: [GuidePageSetting] {
        let epoch = model.epoch
        let selection: GuidePageSetting = model.catalog.identifiers.isEmpty
            ? .readOnly("selected_background", label: NSLocalizedString("当前背景图", comment: ""), value: { .string("") })
            : .string("selected_background", label: NSLocalizedString("当前背景图", comment: ""), allowedValues: model.catalog.identifiers,
                      get: { model.selectedFile?.id ?? "" }, set: { model.select($0, expectedEpoch: epoch) })
        return [
            .readOnly("available_backgrounds", label: NSLocalizedString("可用背景", comment: ""), value: { model.catalog.guideValue }),
            selection,
            .readOnly("manual_file_operations", label: NSLocalizedString("导入背景", comment: ""), value: { .bool(true) })
        ]
    }
}
