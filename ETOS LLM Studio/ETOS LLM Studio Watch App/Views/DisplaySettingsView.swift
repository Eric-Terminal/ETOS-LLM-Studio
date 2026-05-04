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
    @ObservedObject private var appearanceProfileManager = ChatAppearanceProfileManager.shared
    
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

            Section(footer: Text(NSLocalizedString("「沉浸视窗」如轻纱般覆于当前对话之上，让您时刻感知聊天背景；「独立页面」则以利落的滑动展开全新视图，带来更纯粹的视觉体验。", comment: ""))) {
                Picker(NSLocalizedString("界面架构", comment: ""), selection: chatNavigationModeBinding) {
                    Text(NSLocalizedString("沉浸视窗", comment: "")).tag(ChatNavigationMode.legacyOverlay)
                    Text(NSLocalizedString("独立页面", comment: "")).tag(ChatNavigationMode.nativeNavigation)
                }
            }

            Section(footer: Text(NSLocalizedString("需要先将界面架构切换为“独立页面”才可开启彩色设置图标；沉浸视窗会继续使用单色线条图标。", comment: ""))) {
                Toggle(NSLocalizedString("彩色设置图标", comment: ""), isOn: colorfulSettingsIconsBinding)
                    .disabled(!canUseColorfulSettingsIcons)
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
                NavigationLink {
                    WatchChatAppearanceProfileSettingsView()
                } label: {
                    Label(NSLocalizedString("颜色配置", comment: ""), systemImage: "paintpalette")
                }
            } header: {
                Text(NSLocalizedString("聊天颜色自定义", comment: ""))
            } footer: {
                Text(String(format: NSLocalizedString("当前使用：%@", comment: ""), displaySettingsProfileDisplayName(appearanceProfileManager.activeProfile)))
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

    private var normalizedBackgroundOpacity: Double {
        WatchBackgroundOpacitySetting.normalized(backgroundOpacity)
    }

    private var backgroundOpacityBinding: Binding<Double> {
        Binding(
            get: { normalizedBackgroundOpacity },
            set: { backgroundOpacity = WatchBackgroundOpacitySetting.normalized($0) }
        )
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
            Text(language.nativeDisplayName)
        }
    }
}
