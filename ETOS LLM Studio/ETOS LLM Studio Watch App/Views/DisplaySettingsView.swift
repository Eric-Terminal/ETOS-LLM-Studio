// ============================================================================
// DisplaySettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 显示设置视图
//
// 功能特性:
// - 提供所有与UI显示相关的设置选项
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct DisplaySettingsView: View {
    
    // MARK: - 绑定
    
    @Binding var enableMarkdown: Bool
    @Binding var enableBackground: Bool
    @Binding var backgroundBlur: Double
    @Binding var backgroundOpacity: Double
    @Binding var enableAutoRotateBackground: Bool
    @Binding var currentBackgroundImage: String
    @Binding var backgroundContentMode: String // "fill" 或 "fit"
    @Binding var enableLiquidGlass: Bool // 新增绑定
    @Binding var enableAdvancedRenderer: Bool
    @Binding var enableAutoReasoningPreview: Bool
    @Binding var enableNoBubbleUI: Bool

    @AppStorage(ChatNavigationMode.storageKey) private var chatNavigationModeRawValue: String = ChatNavigationMode.defaultMode.rawValue
    @AppStorage(SettingsIconAppearancePreference.storageKey) private var useColorfulSettingsIcons: Bool = false
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguageRawValue: String = AppLanguagePreference.defaultLanguage.rawValue
    @AppStorage("enableCustomUserBubbleColor") private var enableCustomUserBubbleColor: Bool = false
    @AppStorage("customUserBubbleColorHex") private var customUserBubbleColorHex: String = "3D8FF2FF"
    @AppStorage("enableCustomAssistantBubbleColor") private var enableCustomAssistantBubbleColor: Bool = false
    @AppStorage("customAssistantBubbleColorHex") private var customAssistantBubbleColorHex: String = "F2F2F7FF"
    @AppStorage("enableCustomLightTextColor") private var enableCustomLightTextColor: Bool = false
    @AppStorage("customLightTextColorHex") private var customLightTextColorHex: String = "1C1C1EFF"
    @AppStorage("enableCustomDarkTextColor") private var enableCustomDarkTextColor: Bool = false
    @AppStorage("customDarkTextColorHex") private var customDarkTextColorHex: String = "FFFFFFFF"
    
    // MARK: - 属性
    
    let allBackgrounds: [String]
    
    // MARK: - 视图主体
    
    var body: some View {
        Form {
            Section(header: Text("背景")) {
                Toggle("显示背景", isOn: $enableBackground)
                
                if enableBackground {
                    // 背景填充模式选择
                    Picker("填充模式", selection: $backgroundContentMode) {
                        Text("填充 (居中裁剪)").tag("fill")
                        Text("适应 (完整显示)").tag("fit")
                    }
                    
                    VStack(alignment: .leading) {
                        Text(String(format: NSLocalizedString("背景模糊: %.1f", comment: ""), backgroundBlur))
                        Slider(value: $backgroundBlur, in: 0...25, step: 0.5)
                    }
                    
                    VStack(alignment: .leading) {
                        Text(String(format: NSLocalizedString("背景不透明度: %.2f", comment: ""), normalizedBackgroundOpacity))
                        Slider(value: backgroundOpacityBinding, in: WatchBackgroundOpacitySetting.allowedRange, step: 0.05)
                    }
                    
                    Toggle("背景随机轮换", isOn: $enableAutoRotateBackground)
                    
                    NavigationLink(destination: BackgroundPickerView(
                        allBackgrounds: allBackgrounds,
                        selectedBackground: $currentBackgroundImage
                    )) {
                        Text("选择背景")
                    }
                }
            }

            Section {
                Toggle("渲染 Markdown", isOn: $enableMarkdown)
                if enableMarkdown {
                    Toggle("使用高级渲染器", isOn: $enableAdvancedRenderer)
                }
            } header: {
                Text("内容显示")
            } footer: {
                if enableMarkdown {
                    Text("启用后可使用更强的 Markdown/LaTeX 渲染能力。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("App 语言", selection: appLanguageBinding) {
                    ForEach(AppLanguagePreference.allCases) { language in
                        appLanguageLabel(language)
                            .tag(language.rawValue)
                    }
                }
            } header: {
                Text("语言")
            } footer: {
                Text("手动选择 App 界面语言；跟随系统时会使用设备当前语言。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("界面架构", selection: chatNavigationModeBinding) {
                    Text("沉浸浮层").tag(ChatNavigationMode.legacyOverlay)
                    Text("原生导航").tag(ChatNavigationMode.nativeNavigation)
                }
            } footer: {
                Text("「沉浸浮层」会在当前聊天页叠加半透明菜单，保留背景画面；「原生导航」则采用纯色底层的页面推拉切换，层级与手势更清晰。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("彩色设置图标", isOn: colorfulSettingsIconsBinding)
                    .disabled(!canUseColorfulSettingsIcons)
            } footer: {
                Text("需要先将界面架构切换为“原生导航”才可开启彩色设置图标；沉浸浮层会继续使用单色线条图标。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    WatchFontSettingsView()
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

            if #available(watchOS 26.0, *) {
                Section(header: Text("特效")) {
                    Toggle("启用液态玻璃", isOn: $enableLiquidGlass)
                }
            }

            Section {
                Toggle("自定义用户气泡颜色", isOn: $enableCustomUserBubbleColor)
                if enableCustomUserBubbleColor {
                    colorEditorLink(
                        title: "用户气泡颜色",
                        hex: $customUserBubbleColorHex,
                        fallback: defaultUserBubbleColor,
                        description: "影响你发送消息的气泡背景颜色。"
                    )
                }

                Toggle("自定义助手气泡颜色（含 Tool）", isOn: $enableCustomAssistantBubbleColor)
                if enableCustomAssistantBubbleColor {
                    colorEditorLink(
                        title: "助手气泡颜色",
                        hex: $customAssistantBubbleColorHex,
                        fallback: defaultAssistantBubbleColor,
                        description: "影响助手消息与 Tool 消息的气泡背景颜色。"
                    )
                }

                Toggle("自定义白天文字颜色", isOn: $enableCustomLightTextColor)
                if enableCustomLightTextColor {
                    colorEditorLink(
                        title: "白天文字颜色",
                        hex: $customLightTextColorHex,
                        fallback: defaultLightTextColor,
                        description: "在浅色模式下覆盖聊天文本颜色。"
                    )
                }

                Toggle("自定义夜览文字颜色", isOn: $enableCustomDarkTextColor)
                if enableCustomDarkTextColor {
                    colorEditorLink(
                        title: "夜览文字颜色",
                        hex: $customDarkTextColorHex,
                        fallback: defaultDarkTextColor,
                        description: "在深色模式下覆盖聊天文本颜色。"
                    )
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
        .onAppear {
            normalizeBackgroundOpacityIfNeeded()
            disableColorfulSettingsIconsIfNeeded()
        }
        .onChange(of: chatNavigationModeRawValue) { _, _ in
            disableColorfulSettingsIconsIfNeeded()
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

    private var defaultLightTextColor: Color {
        .init(.sRGB, red: 0.11, green: 0.11, blue: 0.12, opacity: 1)
    }

    private var defaultDarkTextColor: Color {
        .white
    }

    private var normalizedBackgroundOpacity: Double {
        WatchBackgroundOpacitySetting.normalized(backgroundOpacity)
    }

    private var backgroundOpacityBinding: Binding<Double> {
        Binding(
            get: { normalizedBackgroundOpacity },
            set: { backgroundOpacity = WatchBackgroundOpacitySetting.normalized($0) }
        )
    }

    @ViewBuilder
    private func colorEditorLink(
        title: String,
        hex: Binding<String>,
        fallback: Color,
        description: String
    ) -> some View {
        let localizedTitle = NSLocalizedString(title, comment: "")
        NavigationLink {
            WatchColorEditorView(
                title: title,
                hexValue: hex,
                fallback: fallback,
                description: description
            )
        } label: {
            HStack(spacing: 8) {
                Text(String(format: NSLocalizedString("设置%@", comment: ""), localizedTitle))
                Spacer(minLength: 8)
                Circle()
                    .fill(ChatAppearanceColorCodec.color(from: hex.wrappedValue, fallback: fallback))
                    .overlay(
                        Circle()
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
                    .frame(width: 14, height: 14)
            }
        }
    }

    private var chatNavigationModeBinding: Binding<ChatNavigationMode> {
        Binding(
            get: { ChatNavigationMode.resolvedMode(rawValue: chatNavigationModeRawValue) },
            set: { chatNavigationModeRawValue = $0.rawValue }
        )
    }

    private var canUseColorfulSettingsIcons: Bool {
        ChatNavigationMode.resolvedMode(rawValue: chatNavigationModeRawValue) == .nativeNavigation
    }

    private var colorfulSettingsIconsBinding: Binding<Bool> {
        Binding(
            get: { canUseColorfulSettingsIcons && useColorfulSettingsIcons },
            set: { useColorfulSettingsIcons = canUseColorfulSettingsIcons && $0 }
        )
    }

    private func disableColorfulSettingsIconsIfNeeded() {
        if !canUseColorfulSettingsIcons {
            useColorfulSettingsIcons = false
        }
    }

    private func normalizeBackgroundOpacityIfNeeded() {
        if normalizedBackgroundOpacity != backgroundOpacity {
            backgroundOpacity = normalizedBackgroundOpacity
        }
    }

    private var appLanguageBinding: Binding<String> {
        Binding(
            get: { appLanguageRawValue },
            set: { newValue in
                appLanguageRawValue = newValue
                AppLanguageRuntime.apply(rawValue: newValue)
            }
        )
    }

    @ViewBuilder
    private func appLanguageLabel(_ language: AppLanguagePreference) -> some View {
        if language == .system {
            Text("跟随系统")
        } else {
            Text(verbatim: language.nativeDisplayName)
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

private struct WatchColorEditorView: View {
    let title: String
    @Binding var hexValue: String
    let fallback: Color
    let description: String

    @State private var red: Double = 0
    @State private var green: Double = 0
    @State private var blue: Double = 0
    @State private var alpha: Double = 1

    private var previewColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    private var previewHex: String {
        ChatAppearanceColorCodec.hexRGBA(from: previewColor) ?? hexValue
    }

    var body: some View {
        Form {
            Section {
                Text(LocalizedStringKey(description))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(previewColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
                    .frame(height: 36)
                Text(previewHex)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            } header: {
                Text("预览")
            }

            Section {
                channelSlider(title: "红", value: $red, tint: .red)
                channelSlider(title: "绿", value: $green, tint: .green)
                channelSlider(title: "蓝", value: $blue, tint: .blue)
            } header: {
                Text("RGB")
            }

            Section {
                opacitySlider(value: $alpha)
            } header: {
                Text("透明度")
            }

            Section {
                Button("恢复默认") {
                    applyFallbackColor()
                }
            }
        }
        .navigationTitle(LocalizedStringKey(title))
        .onAppear {
            loadFromHex()
        }
        .onChange(of: red) { _, _ in
            persistColor()
        }
        .onChange(of: green) { _, _ in
            persistColor()
        }
        .onChange(of: blue) { _, _ in
            persistColor()
        }
        .onChange(of: alpha) { _, _ in
            persistColor()
        }
    }

    @ViewBuilder
    private func channelSlider(title: String, value: Binding<Double>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(LocalizedStringKey(title))
                Spacer(minLength: 8)
                Text("\(Int((value.wrappedValue * 255).rounded()))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: 0...1, step: 1.0 / 255.0)
                .tint(tint)
        }
    }

    @ViewBuilder
    private func opacitySlider(value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("不透明度")
                Spacer(minLength: 8)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: 0...1, step: 0.05)
                .tint(.accentColor)
        }
    }

    private func loadFromHex() {
        let color = ChatAppearanceColorCodec.color(from: hexValue, fallback: fallback)
        guard let rgba = ChatAppearanceColorCodec.rgbaComponents(from: color) else {
            applyFallbackColor()
            return
        }
        red = rgba.red
        green = rgba.green
        blue = rgba.blue
        alpha = rgba.alpha
        persistColor()
    }

    private func persistColor() {
        if let encoded = ChatAppearanceColorCodec.hexRGBA(from: previewColor) {
            hexValue = encoded
        }
    }

    private func applyFallbackColor() {
        if let rgba = ChatAppearanceColorCodec.rgbaComponents(from: fallback) {
            red = rgba.red
            green = rgba.green
            blue = rgba.blue
            alpha = rgba.alpha
            persistColor()
        }
    }
}

private struct WatchFontSettingsView: View {
    @AppStorage(FontLibrary.customFontEnabledStorageKey) private var isCustomFontEnabled: Bool = true
    @AppStorage(FontLibrary.fallbackScopeStorageKey) private var fallbackScopeRawValue: String = FontFallbackScope.segment.rawValue
    @AppStorage(FontLibrary.fontScaleStorageKey) private var customFontScale: Double = FontLibrary.defaultFontScale
    @State private var assets: [FontAssetRecord] = []
    @State private var routes: FontRouteConfiguration = .init()
    @State private var selectedRole: FontSemanticRole = .body
    @State private var isShowingIntroDetails = false
    @State private var showAddAssetDialog = false
    @State private var importURLText: String = ""
    @State private var isImportingFromURL: Bool = false
    @State private var importErrorMessage: String?

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "字体样式优先级",
                    summary: "按槽位管理字体顺序，越靠上优先级越高。",
                    details: """
                    快速上手
                    1. 可在手表粘贴字体链接直接导入，或在 iPhone 端导入后同步到手表。
                    2. 选择样式槽位（正文 / 斜体 / 粗体 / 代码）。
                    3. 用上下箭头调整顺序。
                    4. 点击“添加字体到当前槽位”补入缺失字体。
                    5. 对槽位内字体右滑可“移除”，仅移出当前槽位。

                    规则说明
                    • 每个槽位互相独立。
                    • 同一字体可加入多个槽位。
                    • 当前槽位无可用字体时自动回退系统字体。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle("启用自定义字体", isOn: $isCustomFontEnabled)
            } footer: {
                Text("关闭后会全局回退系统字体；已导入字体与优先级配置会保留。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            fontScaleSection

            Section("回退范围") {
                Picker("字体回退范围", selection: fallbackScopeBinding) {
                    ForEach(FontFallbackScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Text(fallbackScope.summary)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("字体来源") {
                TextField("字体文件链接", text: $importURLText.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    importFontsFromURL()
                } label: {
                    Label(isImportingFromURL ? "正在下载并导入..." : "从链接导入", systemImage: "link.badge.plus")
                }
                .disabled(isImportingFromURL || importURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isImportingFromURL {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在下载并导入...")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("支持 http/https 的 TTF / OTF / TTC / WOFF / WOFF2 链接。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let importErrorMessage, !importErrorMessage.isEmpty {
                Section("导入错误") {
                    Text(importErrorMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Section("已导入字体") {
                if assets.isEmpty {
                    Text("暂无字体，可在手表上通过链接导入，或在 iPhone 导入后同步。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(assets) { asset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(asset.displayName)
                                .etFont(.footnote)
                            Text(asset.postScriptName)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section(
                header: Text("样式优先级"),
                footer: Text("使用上下箭头调整顺序；可通过“添加字体到当前槽位”补入未加入的字体；对槽位内字体右滑可移除。越靠上优先级越高。")
            ) {
                Picker("样式槽位", selection: $selectedRole) {
                    ForEach(FontSemanticRole.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                if chainRecords.isEmpty {
                    Text("当前槽位为空，使用系统字体。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(chainRecords.enumerated()), id: \.element.id) { index, asset in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(asset.displayName)
                                    .foregroundStyle(.primary)
                            }
                            Spacer(minLength: 8)
                            HStack(spacing: 4) {
                                Button {
                                    moveAsset(at: index, offset: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)

                                Button {
                                    moveAsset(at: index, offset: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index >= chainRecords.count - 1)
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
                }

                if availableAssetsForSelectedRole.isEmpty {
                    Text("当前槽位没有可添加字体。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        showAddAssetDialog = true
                    } label: {
                        Label("添加字体到当前槽位", systemImage: "plus.circle")
                    }
                }
            }

            Section("预览") {
                Text("风来疏竹，风过而竹不留声。")
                    .font(FontRoutePreview.font(for: .body, sample: "风来疏竹，风过而竹不留声。", size: 14))
                Text("Emphasis")
                    .font(FontRoutePreview.font(for: .emphasis, sample: "Emphasis", size: 14))
                    .italic()
                Text("Strong")
                    .font(FontRoutePreview.font(for: .strong, sample: "Strong", size: 14))
                    .fontWeight(.bold)
                Text("let value = 42")
                    .font(FontRoutePreview.font(for: .code, sample: "let value = 42", size: 13))
            }
        }
        .navigationTitle("字体设置")
        .onAppear {
            FontLibrary.registerAllFontsIfNeeded()
            reloadData()
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
        .onChange(of: customFontScale) { _, newValue in
            let normalizedValue = FontLibrary.normalizedFontScale(newValue)
            if normalizedValue != newValue {
                customFontScale = normalizedValue
                return
            }
            NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
        }
        .confirmationDialog(
            "添加字体到当前槽位",
            isPresented: $showAddAssetDialog,
            titleVisibility: .visible
        ) {
            ForEach(availableAssetsForSelectedRole) { asset in
                Button(asset.displayName) {
                    addAssetToSelectedRole(asset.id)
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .etFont(.footnote.weight(.semibold))
            Text(summary)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text("进一步了解…")
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(details)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
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

    private var fallbackScope: FontFallbackScope {
        FontFallbackScope(rawValue: fallbackScopeRawValue) ?? .segment
    }

    private var fallbackScopeBinding: Binding<FontFallbackScope> {
        Binding(
            get: { fallbackScope },
            set: { fallbackScopeRawValue = $0.rawValue }
        )
    }

    private var fontScaleBinding: Binding<Double> {
        Binding(
            get: { FontLibrary.normalizedFontScale(customFontScale) },
            set: { customFontScale = FontLibrary.normalizedFontScale($0) }
        )
    }

    private var fontScaleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("字号比例")
                    Spacer(minLength: 8)
                    Text("\(Int((fontScaleBinding.wrappedValue * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: fontScaleBinding,
                    in: FontLibrary.minimumFontScale...FontLibrary.maximumFontScale,
                    step: FontLibrary.fontScaleStep
                )
            }
            Button("恢复默认字号") {
                fontScaleBinding.wrappedValue = FontLibrary.defaultFontScale
            }
            .disabled(abs(fontScaleBinding.wrappedValue - FontLibrary.defaultFontScale) < 0.001)
        } header: {
            Text("字体大小")
        } footer: {
            Text("仅调整自定义字体的显示大小，范围为 50% 到 200%；系统动态字号仍会继续生效。")
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func moveAsset(at index: Int, offset: Int) {
        var chain = routes.chain(for: selectedRole)
        let target = index + offset
        guard chain.indices.contains(index), chain.indices.contains(target) else { return }
        chain.swapAt(index, target)
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

    private func removeAssetFromSelectedRole(_ assetID: UUID) {
        var chain = routes.chain(for: selectedRole)
        guard chain.contains(assetID) else { return }
        chain.removeAll { $0 == assetID }
        routes.setChain(chain, for: selectedRole)
        FontLibrary.updateChain(chain, for: selectedRole)
        NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
    }

    private func importFontsFromURL() {
        let trimmed = importURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            importErrorMessage = "链接不能为空。"
            return
        }
        guard let url = URL(string: trimmed) else {
            importErrorMessage = "链接格式无效，请输入完整 URL。"
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            importErrorMessage = "仅支持 http/https 链接。"
            return
        }

        importErrorMessage = nil
        isImportingFromURL = true

        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 45
                let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    await MainActor.run {
                        importErrorMessage = "下载失败：HTTP \(httpResponse.statusCode)"
                        isImportingFromURL = false
                    }
                    return
                }

                let fileName = suggestedRemoteFontFileName(from: url, response: response, data: data)
                _ = try FontLibrary.importFont(data: data, fileName: fileName)

                await MainActor.run {
                    FontLibrary.registerAllFontsIfNeeded()
                    reloadData()
                    NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
                    importURLText = ""
                    importErrorMessage = nil
                    isImportingFromURL = false
                }
            } catch {
                await MainActor.run {
                    importErrorMessage = error.localizedDescription
                    isImportingFromURL = false
                }
            }
        }
    }

    private func suggestedRemoteFontFileName(from url: URL, response: URLResponse, data: Data) -> String {
        var fileName = response.suggestedFilename?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if fileName.isEmpty {
            fileName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if fileName.isEmpty || fileName == "/" {
            fileName = "font-from-url"
        }

        let lowercased = fileName.lowercased()
        let allowedExtensions: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2"]
        if allowedExtensions.contains((lowercased as NSString).pathExtension) {
            return fileName
        }

        let inferredExtension = inferredFontExtension(response: response, data: data) ?? "ttf"
        return "\(fileName).\(inferredExtension)"
    }

    private func inferredFontExtension(response: URLResponse, data: Data) -> String? {
        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if contentType.contains("woff2") { return "woff2" }
            if contentType.contains("woff") { return "woff" }
            if contentType.contains("ttc") || contentType.contains("collection") { return "ttc" }
            if contentType.contains("otf") || contentType.contains("opentype") { return "otf" }
            if contentType.contains("ttf") || contentType.contains("truetype") || contentType.contains("sfnt") { return "ttf" }
        }

        let header = [UInt8](data.prefix(4))
        if header == [0x77, 0x4F, 0x46, 0x32] { return "woff2" } // wOF2
        if header == [0x77, 0x4F, 0x46, 0x46] { return "woff" } // wOFF
        if header == [0x74, 0x74, 0x63, 0x66] { return "ttc" } // ttcf
        if header == [0x4F, 0x54, 0x54, 0x4F] { return "otf" } // OTTO
        if header == [0x00, 0x01, 0x00, 0x00] { return "ttf" }
        return nil
    }
}

private enum FontRoutePreview {
    static func font(for role: FontSemanticRole, sample: String, size: CGFloat) -> Font {
        let scaledSize = size * CGFloat(FontLibrary.customFontScale)
        if let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: sample) {
            return .custom(postScriptName, size: scaledSize)
        }
        switch role {
        case .code:
            return .system(size: scaledSize, design: .monospaced)
        default:
            return .system(size: scaledSize)
        }
    }
}
