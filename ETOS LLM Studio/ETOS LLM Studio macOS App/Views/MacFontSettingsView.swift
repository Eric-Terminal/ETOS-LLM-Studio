import ETOSCore
import SwiftUI

struct MacFontSettingsView: View {
    @ObservedObject var model: MacFontModel
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var config = AppConfigStore.shared
    @State private var visible = false
    @State private var editing: EditTarget?
    @State private var deleting: DeleteTarget?
    private struct EditTarget: Identifiable { let id = UUID(); let catalog: MacFontCatalog; let epoch: UUID }
    private struct DeleteTarget { let asset: FontAssetRecord; let snapshot: FontLibrarySnapshot; let epoch: UUID }
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended }
    private var scale: Binding<Double> {
        Binding(get: { FontLibrary.normalizedFontScale(config.fontCustomScale) }, set: { config.fontCustomScale = FontLibrary.normalizedFontScale($0) })
    }
    private var spacing: Binding<Double> {
        Binding(get: { FontLibrary.normalizedLineSpacingEm(config.fontLineSpacingEmIOS, fallback: FontLibrary.defaultIOSLineSpacingEm) },
                set: { config.fontLineSpacingEmIOS = FontLibrary.normalizedLineSpacingEm($0, fallback: FontLibrary.defaultIOSLineSpacingEm) })
    }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "fonts", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 字体设置使用说明", comment: ""), documentID: "settings-display", isActive: available)
                Toggle(NSLocalizedString("启用自定义字体", comment: ""), isOn: $config.fontUseCustomFonts)
                Picker(NSLocalizedString("字体回退范围", comment: ""), selection: $config.fontFallbackScope) {
                    ForEach(FontFallbackScope.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text(NSLocalizedString("关闭后全局回退为系统字体；已导入字体与优先级配置会保留。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(NSLocalizedString("字号比例", comment: ""), value: String(format: NSLocalizedString("%.0f%%", comment: ""), scale.wrappedValue * 100))
                Slider(value: scale, in: FontLibrary.minimumFontScale...FontLibrary.maximumFontScale, step: FontLibrary.fontScaleStep) {
                    Text(NSLocalizedString("字号比例", comment: ""))
                }
                Button(NSLocalizedString("恢复默认字号", comment: "")) { config.fontCustomScale = FontLibrary.defaultFontScale }
                LabeledContent(NSLocalizedString("聊天正文行距", comment: ""), value: String(format: NSLocalizedString("%.3f em", comment: ""), spacing.wrappedValue))
                Slider(value: spacing, in: FontLibrary.minimumLineSpacingEm...FontLibrary.maximumLineSpacingEm, step: FontLibrary.lineSpacingStepEm) {
                    Text(NSLocalizedString("聊天正文行距", comment: ""))
                }
                Button(NSLocalizedString("恢复默认行距", comment: "")) { config.fontLineSpacingEmIOS = FontLibrary.defaultIOSLineSpacingEm }
            } header: { Text(NSLocalizedString("字体大小", comment: "")) }
            Section {
                Button(NSLocalizedString("上传字体文件", comment: "")) { model.openImportPanel() }.disabled(!model.canEdit)
                Button(NSLocalizedString("刷新", comment: "")) { model.reload() }.disabled(model.isLoading || model.isWorking || model.isImportPanelOpen)
                if let catalog = model.catalog {
                    if catalog.assets.isEmpty {
                        Text(NSLocalizedString("还没有导入字体。支持 TTF / OTF / TTC / WOFF / WOFF2。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(catalog.assets) { asset in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(asset.displayName)
                                Text(asset.postScriptName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { deleting = .init(asset: asset, snapshot: catalog.snapshot, epoch: model.epoch) } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }.disabled(!model.canEdit)
                        }.buttonStyle(.borderless)
                    }
                    Button(NSLocalizedString("字体样式优先级", comment: "")) { editing = .init(catalog: catalog, epoch: model.epoch) }.disabled(!model.canEdit)
                }
            } header: { Text(NSLocalizedString("字体文件", comment: "")) }
            Section {
                MacFontPreview(revision: model.renderRevision)
            } header: { Text(NSLocalizedString("预览", comment: "")) }
            if model.isLoading || model.isWorking { ProgressView() }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .formStyle(.grouped).navigationTitle(NSLocalizedString("字体设置", comment: "")).disabled(!available)
        .onAppear { visible = true; model.reload() }
        .onDisappear { visible = false; model.cancelImportPanel() }
        .onChange(of: model.epoch) { _, _ in editing = nil; deleting = nil }
        .onChange(of: available) { _, value in if !value { editing = nil; deleting = nil; model.cancelImportPanel() } }
        .sheet(item: $editing) { target in MacFontRoutesEditor(model: model, original: target.catalog, epoch: target.epoch, isActive: available) }
        .alert(NSLocalizedString("删除字体", comment: ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard let target = deleting, available else { return }; deleting = nil
                model.delete(target.asset, original: target.snapshot, expectedEpoch: target.epoch)
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { deleting = nil }
        } message: { Text(NSLocalizedString("删除字体也会移除优先级和字体规则中的关联。", comment: "")) }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-fonts-\(model.epoch)"), title: NSLocalizedString("字体设置", comment: ""),
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
            isActive: available && visible && !model.isWorking && !model.isImportPanelOpen && editing == nil && deleting == nil, settings: [
                .bool("custom_fonts_enabled", label: NSLocalizedString("启用自定义字体", comment: ""), get: { config.fontUseCustomFonts }, set: { config.fontUseCustomFonts = $0 }),
                .string("fallback_scope", label: NSLocalizedString("字体回退范围", comment: ""), allowedValues: ["segment", "character"], get: { config.fontFallbackScope }, set: { config.fontFallbackScope = $0 }),
                .double("font_scale", label: NSLocalizedString("字号比例", comment: ""), range: 0.5...2, get: { scale.wrappedValue }, set: { scale.wrappedValue = $0 }),
                .double("line_spacing_em", label: NSLocalizedString("聊天正文行距", comment: ""), range: 0...1, get: { spacing.wrappedValue }, set: { spacing.wrappedValue = $0 }),
                .readOnly("fonts", label: NSLocalizedString("字体文件", comment: ""), value: { model.catalog?.guideValue ?? .array([]) }),
                .readOnly("routes_require_navigation", label: NSLocalizedString("字体样式优先级", comment: ""), value: { .bool(true) })
            ])
    }
}
