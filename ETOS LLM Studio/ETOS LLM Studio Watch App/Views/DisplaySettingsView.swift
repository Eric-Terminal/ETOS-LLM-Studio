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
            Section(header: Text(NSLocalizedString("背景", comment: ""))) {
                Toggle(NSLocalizedString("显示背景", comment: ""), isOn: $enableBackground)
                
                if enableBackground {
                    // 背景填充模式选择
                    Picker(NSLocalizedString("填充模式", comment: ""), selection: $backgroundContentMode) {
                        Text(NSLocalizedString("填充 (居中裁剪)", comment: "")).tag("fill")
                        Text(NSLocalizedString("适应 (完整显示)", comment: "")).tag("fit")
                    }
                    
                    VStack(alignment: .leading) {
                        Text(String(format: NSLocalizedString("背景模糊: %.1f", comment: ""), backgroundBlur))
                        Slider(value: $backgroundBlur, in: 0...25, step: 0.5)
                    }
                    
                    VStack(alignment: .leading) {
                        Text(String(format: NSLocalizedString("背景不透明度: %.2f", comment: ""), normalizedBackgroundOpacity))
                        Slider(value: backgroundOpacityBinding, in: WatchBackgroundOpacitySetting.allowedRange, step: 0.05)
                    }
                    
                    Toggle(NSLocalizedString("背景随机轮换", comment: ""), isOn: $enableAutoRotateBackground)
                    
                    NavigationLink(destination: BackgroundPickerView(
                        allBackgrounds: allBackgrounds,
                        selectedBackground: $currentBackgroundImage
                    )) {
                        Text(NSLocalizedString("选择背景", comment: ""))
                    }
                }
            }

            Section {
                Toggle(NSLocalizedString("渲染 Markdown", comment: ""), isOn: $enableMarkdown)
                if enableMarkdown {
                    Toggle(NSLocalizedString("使用高级渲染器", comment: ""), isOn: $enableAdvancedRenderer)
                }
            } header: {
                Text(NSLocalizedString("内容显示", comment: ""))
            } footer: {
                if enableMarkdown {
                    Text(NSLocalizedString("启用后可使用更强的 Markdown/LaTeX 渲染能力。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker(NSLocalizedString("App 语言", comment: ""), selection: appLanguageBinding) {
                    ForEach(AppLanguagePreference.allCases) { language in
                        appLanguageLabel(language)
                            .tag(language.rawValue)
                    }
                }
            } header: {
                Text(NSLocalizedString("语言", comment: ""))
            } footer: {
                Text(NSLocalizedString("手动选择 App 界面语言；跟随系统时会使用设备当前语言。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(NSLocalizedString("界面架构", comment: ""), selection: chatNavigationModeBinding) {
                    Text(NSLocalizedString("沉浸浮层", comment: "")).tag(ChatNavigationMode.legacyOverlay)
                    Text(NSLocalizedString("原生导航", comment: "")).tag(ChatNavigationMode.nativeNavigation)
                }
            } footer: {
                Text(NSLocalizedString("「沉浸浮层」会在当前聊天页叠加半透明菜单，保留背景画面；「原生导航」则采用纯色底层的页面推拉切换，层级与手势更清晰。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(NSLocalizedString("彩色设置图标", comment: ""), isOn: colorfulSettingsIconsBinding)
                    .disabled(!canUseColorfulSettingsIcons)
            } footer: {
                Text(NSLocalizedString("需要先将界面架构切换为“原生导航”才可开启彩色设置图标；沉浸浮层会继续使用单色线条图标。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    WatchFontSettingsView()
                } label: {
                    Label(NSLocalizedString("字体设置", comment: ""), systemImage: "textformat.alt")
                }
            }

            Section {
                Toggle(NSLocalizedString("无气泡UI", comment: ""), isOn: $enableNoBubbleUI)
            } footer: {
                Text(NSLocalizedString("开启后聊天气泡背景会透明化，并自动放宽消息文本宽度。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(NSLocalizedString("自动预览思考过程", comment: ""), isOn: $enableAutoReasoningPreview)
            } footer: {
                Text(NSLocalizedString("开启后，AI 回复仅有思考内容时会自动展开；一旦出现正文会自动收起。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            if #available(watchOS 26.0, *) {
                Section(header: Text(NSLocalizedString("特效", comment: ""))) {
                    Toggle(NSLocalizedString("启用液态玻璃", comment: ""), isOn: $enableLiquidGlass)
                }
            }

            Section {
                Toggle(NSLocalizedString("自定义用户气泡颜色", comment: ""), isOn: $enableCustomUserBubbleColor)
                if enableCustomUserBubbleColor {
                    colorEditorLink(
                        title: "用户气泡颜色",
                        hex: $customUserBubbleColorHex,
                        fallback: defaultUserBubbleColor,
                        description: "影响你发送消息的气泡背景颜色。"
                    )
                }

                Toggle(NSLocalizedString("自定义助手气泡颜色（含 Tool）", comment: ""), isOn: $enableCustomAssistantBubbleColor)
                if enableCustomAssistantBubbleColor {
                    colorEditorLink(
                        title: "助手气泡颜色",
                        hex: $customAssistantBubbleColorHex,
                        fallback: defaultAssistantBubbleColor,
                        description: "影响助手消息与 Tool 消息的气泡背景颜色。"
                    )
                }

                Toggle(NSLocalizedString("自定义白天文字颜色", comment: ""), isOn: $enableCustomLightTextColor)
                if enableCustomLightTextColor {
                    colorEditorLink(
                        title: "白天文字颜色",
                        hex: $customLightTextColorHex,
                        fallback: defaultLightTextColor,
                        description: "在浅色模式下覆盖聊天文本颜色。"
                    )
                }

                Toggle(NSLocalizedString("自定义夜览文字颜色", comment: ""), isOn: $enableCustomDarkTextColor)
                if enableCustomDarkTextColor {
                    colorEditorLink(
                        title: "夜览文字颜色",
                        hex: $customDarkTextColorHex,
                        fallback: defaultDarkTextColor,
                        description: "在深色模式下覆盖聊天文本颜色。"
                    )
                }

                if hasAnyCustomColorOverride {
                    Button(NSLocalizedString("恢复默认聊天颜色", comment: "")) {
                        resetCustomChatColors()
                    }
                }
            } header: {
                Text(NSLocalizedString("聊天颜色自定义", comment: ""))
            } footer: {
                Text(NSLocalizedString("默认全部关闭时，聊天配色与当前版本完全一致。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("显示设置", comment: ""))
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
            Text(NSLocalizedString("跟随系统", comment: ""))
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
                Text(NSLocalizedString("预览", comment: ""))
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
                Text(NSLocalizedString("透明度", comment: ""))
            }

            Section {
                Button(NSLocalizedString("恢复默认", comment: "")) {
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
                Text(NSLocalizedString("不透明度", comment: ""))
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
                Toggle(NSLocalizedString("启用自定义字体", comment: ""), isOn: $isCustomFontEnabled)
            } footer: {
                Text(NSLocalizedString("关闭后会全局回退系统字体；已导入字体与优先级配置会保留。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            fontScaleSection

            Section(NSLocalizedString("回退范围", comment: "")) {
                Picker(NSLocalizedString("字体回退范围", comment: ""), selection: fallbackScopeBinding) {
                    ForEach(FontFallbackScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Text(fallbackScope.summary)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("字体来源", comment: "")) {
                TextField(NSLocalizedString("字体文件链接", comment: ""), text: $importURLText.watchKeyboardNewlineBinding())
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
                        Text(NSLocalizedString("正在下载并导入...", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(NSLocalizedString("支持 http/https 的 TTF / OTF / TTC / WOFF / WOFF2 链接。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let importErrorMessage, !importErrorMessage.isEmpty {
                Section(NSLocalizedString("导入错误", comment: "")) {
                    Text(importErrorMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Section(NSLocalizedString("已导入字体", comment: "")) {
                if assets.isEmpty {
                    Text(NSLocalizedString("暂无字体，可在手表上通过链接导入，或在 iPhone 导入后同步。", comment: ""))
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
                header: Text(NSLocalizedString("样式优先级", comment: "")),
                footer: Text(NSLocalizedString("使用上下箭头调整顺序；可通过“添加字体到当前槽位”补入未加入的字体；对槽位内字体右滑可移除。越靠上优先级越高。", comment: ""))
            ) {
                Picker(NSLocalizedString("样式槽位", comment: ""), selection: $selectedRole) {
                    ForEach(FontSemanticRole.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                if chainRecords.isEmpty {
                    Text(NSLocalizedString("当前槽位为空，使用系统字体。", comment: ""))
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
                                Label(NSLocalizedString("移除", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                }

                if availableAssetsForSelectedRole.isEmpty {
                    Text(NSLocalizedString("当前槽位没有可添加字体。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        showAddAssetDialog = true
                    } label: {
                        Label(NSLocalizedString("添加字体到当前槽位", comment: ""), systemImage: "plus.circle")
                    }
                }
            }

            Section(NSLocalizedString("预览", comment: "")) {
                Text(NSLocalizedString("风来疏竹，风过而竹不留声。", comment: ""))
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
        .navigationTitle(NSLocalizedString("字体设置", comment: ""))
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
        .confirmationDialog(NSLocalizedString("添加字体到当前槽位", comment: ""),
            isPresented: $showAddAssetDialog,
            titleVisibility: .visible
        ) {
            ForEach(availableAssetsForSelectedRole) { asset in
                Button(asset.displayName) {
                    addAssetToSelectedRole(asset.id)
                }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
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
                Text(NSLocalizedString("进一步了解…", comment: ""))
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
                    Text(NSLocalizedString("字号比例", comment: ""))
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
            Button(NSLocalizedString("恢复默认字号", comment: "")) {
                fontScaleBinding.wrappedValue = FontLibrary.defaultFontScale
            }
            .disabled(abs(fontScaleBinding.wrappedValue - FontLibrary.defaultFontScale) < 0.001)
        } header: {
            Text(NSLocalizedString("字体大小", comment: ""))
        } footer: {
            Text(NSLocalizedString("仅调整自定义字体的显示大小，范围为 50% 到 200%；系统动态字号仍会继续生效。", comment: ""))
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
