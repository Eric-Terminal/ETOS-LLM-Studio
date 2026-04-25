// ============================================================================
// DisplaySettingsView.swift
// ============================================================================
// DisplaySettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import Shared
import UniformTypeIdentifiers

struct DisplaySettingsView: View {
    @Binding var enableMarkdown: Bool
    @Binding var enableBackground: Bool
    @Binding var backgroundBlur: Double
    @Binding var backgroundOpacity: Double
    @Binding var enableAutoRotateBackground: Bool
    @Binding var currentBackgroundImage: String
    @Binding var backgroundContentMode: String
    @Binding var enableLiquidGlass: Bool
    @Binding var enableAdvancedRenderer: Bool
    @Binding var enableAutoReasoningPreview: Bool
    @Binding var enableNoBubbleUI: Bool

    @AppStorage("enableCustomUserBubbleColor") private var enableCustomUserBubbleColor: Bool = false
    @AppStorage("customUserBubbleColorHex") private var customUserBubbleColorHex: String = "3D8FF2FF"
    @AppStorage("enableCustomAssistantBubbleColor") private var enableCustomAssistantBubbleColor: Bool = false
    @AppStorage("customAssistantBubbleColorHex") private var customAssistantBubbleColorHex: String = "F2F2F7FF"
    @AppStorage("enableCustomLightTextColor") private var enableCustomLightTextColor: Bool = false
    @AppStorage("customLightTextColorHex") private var customLightTextColorHex: String = "1C1C1EFF"
    @AppStorage("enableCustomDarkTextColor") private var enableCustomDarkTextColor: Bool = false
    @AppStorage("customDarkTextColorHex") private var customDarkTextColorHex: String = "FFFFFFFF"
    
    let allBackgrounds: [String]
    
    var body: some View {
        Form {
            Section("背景") {
                Toggle("显示背景", isOn: $enableBackground)
                
                if enableBackground {
                    Picker("填充模式", selection: $backgroundContentMode) {
                        Text("填充 (居中裁剪)").tag("fill")
                        Text("适应 (完整显示)").tag("fit")
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("模糊 %.1f", comment: ""), backgroundBlur))
                        Slider(value: $backgroundBlur, in: 0...25, step: 0.5)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("不透明度 %.2f", comment: ""), backgroundOpacity))
                        Slider(value: $backgroundOpacity, in: 0.1...1.0, step: 0.05)
                    }
                    
                    Toggle("自动轮换背景", isOn: $enableAutoRotateBackground)
                    
                    NavigationLink {
                        BackgroundPickerView(allBackgrounds: allBackgrounds, selectedBackground: $currentBackgroundImage)
                    } label: {
                        Label("选择背景图", systemImage: "photo.on.rectangle")
                    }
                }
            }

            Section {
                Toggle("渲染 Markdown", isOn: $enableMarkdown)
                if enableMarkdown {
                    Toggle("使用高级渲染器", isOn: $enableAdvancedRenderer)
                }
            } header: {
                Text("内容表现")
            } footer: {
                if enableMarkdown {
                    Text("启用后可使用更强的 Markdown/LaTeX 渲染能力。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink {
                    FontSettingsView()
                } label: {
                    Label("字体设置", systemImage: "textformat.alt")
                }
            }

            Section {
                Toggle("无气泡UI", isOn: $enableNoBubbleUI)
            } footer: {
                Text("开启后聊天气泡背景会透明化，并自动放宽消息文本宽度。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("自动预览思考过程", isOn: $enableAutoReasoningPreview)
            } footer: {
                Text("开启后，AI 回复仅有思考内容时会自动展开；一旦出现正文会自动收起。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            if #available(iOS 26.0, *) {
                Section {
                    Toggle("液态玻璃效果", isOn: $enableLiquidGlass)
                }
            }

            Section {
                Toggle("自定义用户气泡颜色", isOn: $enableCustomUserBubbleColor)
                if enableCustomUserBubbleColor {
                    ColorPicker("用户气泡颜色", selection: userBubbleColorBinding, supportsOpacity: false)
                    bubbleOpacitySlider(
                        title: "用户气泡不透明度",
                        opacity: colorOpacityBinding(hex: $customUserBubbleColorHex, fallback: defaultUserBubbleColor)
                    )
                }

                Toggle("自定义助手气泡颜色（含 Tool）", isOn: $enableCustomAssistantBubbleColor)
                if enableCustomAssistantBubbleColor {
                    ColorPicker("助手气泡颜色", selection: assistantBubbleColorBinding, supportsOpacity: false)
                    bubbleOpacitySlider(
                        title: "助手气泡不透明度",
                        opacity: colorOpacityBinding(hex: $customAssistantBubbleColorHex, fallback: defaultAssistantBubbleColor)
                    )
                }

                Toggle("自定义白天文字颜色", isOn: $enableCustomLightTextColor)
                if enableCustomLightTextColor {
                    ColorPicker("白天文字颜色", selection: lightTextColorBinding, supportsOpacity: false)
                }

                Toggle("自定义夜览文字颜色", isOn: $enableCustomDarkTextColor)
                if enableCustomDarkTextColor {
                    ColorPicker("夜览文字颜色", selection: darkTextColorBinding, supportsOpacity: false)
                }

                if hasAnyCustomColorOverride {
                    Button("恢复默认聊天颜色") {
                        resetCustomChatColors()
                    }
                }
            } header: {
                Text("聊天颜色自定义")
            } footer: {
                Text("默认全部关闭时，聊天配色与当前版本完全一致。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("显示设置")
        .onChange(of: enableMarkdown) { _, isEnabled in
            if !isEnabled, enableAdvancedRenderer {
                enableAdvancedRenderer = false
            }
        }
    }

    private var hasAnyCustomColorOverride: Bool {
        enableCustomUserBubbleColor
            || enableCustomAssistantBubbleColor
            || enableCustomLightTextColor
            || enableCustomDarkTextColor
    }

    private var defaultUserBubbleColor: Color {
        .init(.sRGB, red: 0.24, green: 0.56, blue: 0.95, opacity: 1)
    }

    private var defaultAssistantBubbleColor: Color {
        .init(.sRGB, red: 0.949, green: 0.949, blue: 0.969, opacity: 1)
    }

    private var userBubbleColorBinding: Binding<Color> {
        colorBinding(hex: $customUserBubbleColorHex, fallback: defaultUserBubbleColor)
    }

    private var assistantBubbleColorBinding: Binding<Color> {
        colorBinding(hex: $customAssistantBubbleColorHex, fallback: defaultAssistantBubbleColor)
    }

    private var lightTextColorBinding: Binding<Color> {
        colorBinding(hex: $customLightTextColorHex, fallback: .init(.sRGB, red: 0.11, green: 0.11, blue: 0.12, opacity: 1))
    }

    private var darkTextColorBinding: Binding<Color> {
        colorBinding(hex: $customDarkTextColorHex, fallback: .white)
    }

    private func colorBinding(hex: Binding<String>, fallback: Color) -> Binding<Color> {
        Binding(
            get: { ChatAppearanceColorCodec.color(from: hex.wrappedValue, fallback: fallback) },
            set: { newColor in
                let currentAlpha = colorOpacity(hex: hex.wrappedValue, fallback: fallback)
                let adjustedColor = ChatAppearanceColorCodec.replacingAlpha(of: newColor, with: currentAlpha)
                if let encoded = ChatAppearanceColorCodec.hexRGBA(from: adjustedColor) {
                    hex.wrappedValue = encoded
                }
            }
        )
    }

    private func colorOpacityBinding(hex: Binding<String>, fallback: Color) -> Binding<Double> {
        Binding(
            get: { colorOpacity(hex: hex.wrappedValue, fallback: fallback) },
            set: { newOpacity in
                let color = ChatAppearanceColorCodec.color(from: hex.wrappedValue, fallback: fallback)
                let adjustedColor = ChatAppearanceColorCodec.replacingAlpha(of: color, with: newOpacity)
                if let encoded = ChatAppearanceColorCodec.hexRGBA(from: adjustedColor) {
                    hex.wrappedValue = encoded
                }
            }
        )
    }

    private func colorOpacity(hex: String, fallback: Color) -> Double {
        let color = ChatAppearanceColorCodec.color(from: hex, fallback: fallback)
        return ChatAppearanceColorCodec.rgbaComponents(from: color)?.alpha ?? 1
    }

    @ViewBuilder
    private func bubbleOpacitySlider(title: String, opacity: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(LocalizedStringKey(title))
                Spacer(minLength: 8)
                Text("\(Int((opacity.wrappedValue * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: opacity, in: 0...1, step: 0.05)
        }
    }

    private func resetCustomChatColors() {
        enableCustomUserBubbleColor = false
        enableCustomAssistantBubbleColor = false
        enableCustomLightTextColor = false
        enableCustomDarkTextColor = false
        customUserBubbleColorHex = "3D8FF2FF"
        customAssistantBubbleColorHex = "F2F2F7FF"
        customLightTextColorHex = "1C1C1EFF"
        customDarkTextColorHex = "FFFFFFFF"
    }
}

private struct FontSettingsView: View {
    @Environment(\.editMode) private var editMode
    @AppStorage(FontLibrary.customFontEnabledStorageKey) private var isCustomFontEnabled: Bool = true
    @AppStorage(FontLibrary.fallbackScopeStorageKey) private var fallbackScopeRawValue: String = FontFallbackScope.segment.rawValue
    @State private var assets: [FontAssetRecord] = []
    @State private var routes: FontRouteConfiguration = .init()
    @State private var selectedRole: FontSemanticRole = .body
    @State private var isShowingIntroDetails = false
    @State private var showImporter = false
    @State private var importErrorMessage: String?
    @State private var deleteErrorMessage: String?

    var body: some View {
        Form {
            Section {
                settingsIntroCard(
                    title: "字体样式优先级",
                    summary: "管理每个样式槽位的字体候选链；越靠上优先级越高。",
                    details: """
                    怎么用（建议顺序）
                    1. 先在“字体文件”导入你要用的字体。
                    2. 选择样式槽位（正文 / 斜体 / 粗体 / 代码）。
                    3. 点击右上角“编辑”，拖拽右侧把手调整顺序。
                    4. 在编辑状态使用“添加字体到当前槽位”，把漏掉的字体补进来。
                    5. 对槽位内字体右滑可“移除”，仅移出当前槽位，不会删除字体文件。

                    规则说明
                    • 每个槽位都有独立优先级链。
                    • 字体可同时存在于多个槽位。
                    • 槽位内字体都不可用时，会回退到系统字体。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle("启用自定义字体", isOn: $isCustomFontEnabled)
            } footer: {
                Text("关闭后全局回退为系统字体；已导入字体与优先级配置会保留。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            fallbackScopeSection

            fontFilesSection
            stylePrioritySection
            previewSection
        }
        .navigationTitle("字体设置")
        .toolbar {
            EditButton()
        }
        .onAppear {
            reloadData()
            FontLibrary.registerAllFontsIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncFontsUpdated)) { _ in
            reloadData()
        }
        .onChange(of: isCustomFontEnabled) { _, isEnabled in
            if isEnabled {
                FontLibrary.registerAllFontsIfNeeded()
            }
            NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
        }
        .onChange(of: fallbackScopeRawValue) { _, _ in
            FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
            NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: supportedFontTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImportResult(result)
        }
        .alert("导入失败", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "未知错误")
        }
        .alert("删除失败", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "未知错误")
        }
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .etFont(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(summary)
                .etFont(.subheadline)
                .foregroundStyle(.primary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text("进一步了解…")
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(details)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var chainRecords: [FontAssetRecord] {
        let map = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return routes.chain(for: selectedRole).compactMap { map[$0] }
    }

    private var availableAssetsForSelectedRole: [FontAssetRecord] {
        let selectedIDs = Set(routes.chain(for: selectedRole))
        return assets.filter { !selectedIDs.contains($0.id) }
    }

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    private var fallbackScope: FontFallbackScope {
        FontFallbackScope(rawValue: fallbackScopeRawValue) ?? .segment
    }

    private var fallbackScopeBinding: Binding<FontFallbackScope> {
        Binding(
            get: { fallbackScope },
            set: { fallbackScopeRawValue = $0.rawValue }
        )
    }

    private var allFallbackScopes: [FontFallbackScope] {
        FontFallbackScope.allCases
    }

    private var fallbackScopeSection: some View {
        Section {
            NavigationLink {
                FontFallbackScopeSelectionView(
                    allScopes: allFallbackScopes,
                    selectedScope: fallbackScopeBinding
                )
            } label: {
                HStack {
                    Text("字体回退范围")
                    Text(fallbackScope.title)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        } header: {
            Text("回退范围")
        } footer: {
            Text(fallbackScope.summary)
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var fontFilesSection: some View {
        Section("字体文件") {
            Button {
                showImporter = true
            } label: {
                Label("上传字体文件", systemImage: "square.and.arrow.down")
            }
            if assets.isEmpty {
                Text("还没有导入字体。支持 TTF / OTF / TTC / WOFF / WOFF2。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(assets) { asset in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(asset.displayName)
                        Text(asset.postScriptName)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: deleteAssets)
            }
        }
    }

    private var stylePrioritySection: some View {
        Section(
            header: Text("样式优先级"),
            footer: Text("点击右上角“编辑”后，可拖拽右侧把手调整优先级，并通过“添加字体到当前槽位”补入未加入的字体。对槽位内字体右滑可移除。越靠上优先级越高。")
        ) {
            Picker("样式槽位", selection: $selectedRole) {
                ForEach(FontSemanticRole.allCases) { role in
                    Text(role.title).tag(role)
                }
            }
            if chainRecords.isEmpty {
                Text("当前槽位没有可用字体，将使用系统默认字体。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(chainRecords) { asset in
                    HStack {
                        Text(asset.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        HStack(spacing: 6) {
                            Text(asset.postScriptName)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            removeAssetFromSelectedRole(asset.id)
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                    }
                }
                .onMove(perform: movePriority)
                .onDelete(perform: removeAssetsFromSelectedRole)
            }

            if isEditing {
                if availableAssetsForSelectedRole.isEmpty {
                    Text("当前槽位没有可添加字体。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(availableAssetsForSelectedRole) { asset in
                            Button {
                                addAssetToSelectedRole(asset.id)
                            } label: {
                                Text(asset.displayName)
                            }
                        }
                    } label: {
                        Label("添加字体到当前槽位", systemImage: "plus.circle")
                    }
                }
            }
        }
    }

    private var previewSection: some View {
        Section("预览") {
            Text("The quick brown fox jumps over the lazy dog.")
                .font(FontRoutePreview.font(for: .body, sample: "The quick brown fox"))
            Text("中文：风来疏竹，风过而竹不留声。")
                .font(FontRoutePreview.font(for: .body, sample: "风来疏竹，风过而竹不留声。"))
            Text("斜体预览 / Emphasis")
                .font(FontRoutePreview.font(for: .emphasis, sample: "斜体预览 Emphasis"))
                .italic()
            Text("粗体预览 / Strong")
                .font(FontRoutePreview.font(for: .strong, sample: "粗体预览 Strong"))
                .fontWeight(.bold)
            Text("let message = \"Code Preview\"")
                .font(FontRoutePreview.font(for: .code, sample: "let message = \"Code Preview\""))
        }
    }

    private var supportedFontTypes: [UTType] {
        let candidates: [UTType?] = [
            UTType(filenameExtension: "ttf"),
            UTType(filenameExtension: "otf"),
            UTType(filenameExtension: "ttc"),
            UTType(filenameExtension: "woff"),
            UTType(filenameExtension: "woff2"),
            UTType(mimeType: "font/woff"),
            UTType(mimeType: "font/woff2")
        ]

        var seen = Set<String>()
        return candidates
            .compactMap { $0 }
            .filter { seen.insert($0.identifier).inserted }
    }

    private func reloadData() {
        let loadedAssets = FontLibrary.loadAssets()
        if loadedAssets.contains(where: { !$0.isEnabled }) {
            let normalizedAssets = loadedAssets.map { asset in
                var mutable = asset
                mutable.isEnabled = true
                return mutable
            }
            _ = FontLibrary.saveAssets(normalizedAssets)
            assets = normalizedAssets
        } else {
            assets = loadedAssets
        }
        routes = FontLibrary.loadRouteConfiguration()
    }

    private func movePriority(from source: IndexSet, to destination: Int) {
        var chain = routes.chain(for: selectedRole)
        chain.move(fromOffsets: source, toOffset: destination)
        routes.setChain(chain, for: selectedRole)
        FontLibrary.updateChain(chain, for: selectedRole)
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func addAssetToSelectedRole(_ assetID: UUID) {
        var chain = routes.chain(for: selectedRole)
        guard !chain.contains(assetID) else { return }
        chain.append(assetID)
        routes.setChain(chain, for: selectedRole)
        FontLibrary.updateChain(chain, for: selectedRole)
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func removeAssetsFromSelectedRole(at offsets: IndexSet) {
        var chain = routes.chain(for: selectedRole)
        chain.remove(atOffsets: offsets)
        routes.setChain(chain, for: selectedRole)
        FontLibrary.updateChain(chain, for: selectedRole)
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func removeAssetFromSelectedRole(_ assetID: UUID) {
        var chain = routes.chain(for: selectedRole)
        guard chain.contains(assetID) else { return }
        chain.removeAll { $0 == assetID }
        routes.setChain(chain, for: selectedRole)
        FontLibrary.updateChain(chain, for: selectedRole)
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func deleteAssets(at offsets: IndexSet) {
        for index in offsets {
            let target = assets[index]
            do {
                try FontLibrary.deleteFontAsset(id: target.id)
            } catch {
                deleteErrorMessage = error.localizedDescription
            }
        }
        reloadData()
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        case .success(let urls):
            importFonts(from: urls)
        }
    }

    private func importFonts(from urls: [URL]) {
        var firstError: String?
        for url in urls {
            let started = url.startAccessingSecurityScopedResource()
            defer {
                if started {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                _ = try FontLibrary.importFont(data: data, fileName: url.lastPathComponent)
            } catch {
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            }
        }
        FontLibrary.registerAllFontsIfNeeded()
        reloadData()
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
        importErrorMessage = firstError
    }
}

private struct FontFallbackScopeSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let allScopes: [FontFallbackScope]
    @Binding var selectedScope: FontFallbackScope

    var body: some View {
        List {
            ForEach(allScopes) { scope in
                Button {
                    selectedScope = scope
                    dismiss()
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scope.title)
                                .foregroundStyle(.primary)
                            Text(scope.summary)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 8)

                        if selectedScope == scope {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("字体回退范围")
    }
}

private enum FontRoutePreview {
    static func font(for role: FontSemanticRole, sample: String, size: CGFloat = 17) -> Font {
        if let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: sample) {
            return .custom(postScriptName, size: size)
        }
        switch role {
        case .code:
            return .system(size: size, design: .monospaced)
        default:
            return .system(size: size)
        }
    }
}
