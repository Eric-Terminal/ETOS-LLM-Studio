import ETOSCore
import SwiftUI

struct MacBackgroundCropEditor: View {
    @ObservedObject var model: MacBackgroundModel
    @ObservedObject var draft: MacBackgroundCropDraft
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var visible = false
    @State private var dragStart: MacBackgroundCropParameters?
    @GestureState private var translation = CGSize.zero
    private var available: Bool {
        isActive && workspace.canManageLocalModels && !model.isSuspended
            && model.epoch == draft.sourceEpoch && model.cropDraft?.id == draft.id
    }
    private var editable: Bool { available && model.canSaveCrop(draft) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "background-crop", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 背景裁切使用说明", comment: ""), documentID: "settings-display", isActive: available)
                }
                if draft.isPreparing { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                if let error = draft.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if let prepared = draft.prepared {
                    Section {
                        canvas(prepared).frame(minHeight: 260, idealHeight: 320)
                            .disabled(!editable)
                    } footer: {
                        Text(NSLocalizedString("拖动图片调整位置，保存后生成新背景。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        Picker(NSLocalizedString("裁切比例", comment: ""), selection: $draft.parameters.aspect) {
                            ForEach(MacBackgroundCropAspect.allCases) { Text($0.title).tag($0) }
                        }
                        Slider(value: $draft.parameters.zoom, in: 1...6) { Text(NSLocalizedString("缩放", comment: "")) }
                        Slider(value: $draft.parameters.horizontal, in: 0...1) { Text(NSLocalizedString("水平位置", comment: "")) }
                        Slider(value: $draft.parameters.vertical, in: 0...1) { Text(NSLocalizedString("垂直位置", comment: "")) }
                        Button(NSLocalizedString("重置位置与缩放", comment: "")) { draft.reset() }
                    }
                    .disabled(!editable || dragStart != nil)
                }
                if model.isWorking { ProgressView(NSLocalizedString("正在保存…", comment: "")) }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("裁切背景", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { model.cancelCrop(id: draft.id) }.disabled(model.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存为新背景", comment: "")) { model.saveCrop(draft) }
                        .disabled(!editable || dragStart != nil)
                }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false; dragStart = nil }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-background-crop-\(draft.id)-\(draft.sourceEpoch)"),
                title: NSLocalizedString("裁切背景", comment: ""),
                documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
                isActive: visible && editable && dragStart == nil, settings: guideSettings
            )
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 520, minHeight: 620)
        .interactiveDismissDisabled(model.isWorking)
    }

    private func canvas(_ prepared: MacPreparedBackgroundCrop) -> some View {
        GeometryReader { geometry in
            let base = dragStart ?? draft.parameters
            let unit = base.unitRect(for: prepared.pixelSize)
            let ratio = base.aspect.ratio(original: prepared.pixelSize)
            let width = min(geometry.size.width, geometry.size.height * ratio)
            let height = width / ratio
            let renderedSize = CGSize(width: width / unit.width, height: height / unit.height)
            let crop = base.moved(by: translation, displayedImageSize: renderedSize, sourceSize: prepared.pixelSize)
                .unitRect(for: prepared.pixelSize)
            // 画布只做常量几何计算；解码好的预览与最终原图使用同一归一化裁切区域。
            Image(nsImage: prepared.preview).resizable()
                .frame(width: renderedSize.width, height: renderedSize.height)
                .position(x: width / 2 + (0.5 - crop.midX) * renderedSize.width,
                          y: height / 2 + (0.5 - crop.midY) * renderedSize.height)
                .frame(width: width, height: height).clipped().contentShape(Rectangle())
                .gesture(DragGesture()
                    .updating($translation) { value, state, _ in state = value.translation }
                    .onChanged { _ in if dragStart == nil { dragStart = draft.parameters } }
                    .onEnded { value in
                        if editable { draft.parameters = base.moved(by: value.translation, displayedImageSize: renderedSize, sourceSize: prepared.pixelSize) }
                        dragStart = nil
                    })
                .onChange(of: translation) { _, value in if value == .zero { dragStart = nil } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(NSLocalizedString("裁切预览", comment: ""))
        }
    }

    private var guideSettings: [GuidePageSetting] {
        [
            .readOnly("source_background", label: NSLocalizedString("当前背景图", comment: ""), value: { .string(draft.file.id) }),
            .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) }),
            .readOnly("save_creates_new_background", label: NSLocalizedString("保存为新背景", comment: ""), value: { .bool(true) }),
            .string("aspect", label: NSLocalizedString("裁切比例", comment: ""), allowedValues: ["original", "desktop", "phone", "watch", "square"],
                    get: { draft.parameters.aspect.rawValue }, set: { if let aspect = MacBackgroundCropAspect(rawValue: $0) { draft.parameters.aspect = aspect } }),
            .double("zoom", label: NSLocalizedString("缩放", comment: ""), range: 1...6, get: { draft.parameters.zoom }, set: { draft.parameters.zoom = $0 }),
            .double("horizontal", label: NSLocalizedString("水平位置", comment: ""), range: 0...1, get: { draft.parameters.horizontal }, set: { draft.parameters.horizontal = $0 }),
            .double("vertical", label: NSLocalizedString("垂直位置", comment: ""), range: 0...1, get: { draft.parameters.vertical }, set: { draft.parameters.vertical = $0 })
        ]
    }
}
