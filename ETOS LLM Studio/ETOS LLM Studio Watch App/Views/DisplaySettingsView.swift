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
            // MARK: Section 1：界面架构
            Section(footer: Text(NSLocalizedString("「沉浸视窗」如轻纱般覆于当前对话之上，让您时刻感知聊天背景；「独立页面」则以利落的滑动展开全新视图，带来更纯粹的视觉体验。", comment: ""))) {
                Picker(NSLocalizedString("界面架构", comment: ""), selection: chatNavigationModeBinding) {
                    Text(NSLocalizedString("沉浸视窗", comment: "")).tag(ChatNavigationMode.legacyOverlay)
                    Text(NSLocalizedString("独立页面", comment: "")).tag(ChatNavigationMode.nativeNavigation)
                }
            }

            // MARK: Section 2：背景与特效
            Section(header: Text(NSLocalizedString("背景与特效", comment: ""))) {
                Toggle(NSLocalizedString("显示背景", comment: ""), isOn: $enableBackground)
                NavigationLink(destination: BackgroundPickerView(
                    allBackgrounds: allBackgrounds,
                    selectedBackground: $currentBackgroundImage
                )) {
                    Text(NSLocalizedString("选择背景", comment: ""))
                }
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
                if #available(watchOS 26.0, *) {
                    Toggle(NSLocalizedString("启用液态玻璃", comment: ""), isOn: $enableLiquidGlass)
                }
            }

            // MARK: Section 3：对话框与内容
            Section(header: Text(NSLocalizedString("对话框与内容", comment: ""))) {
                Toggle(NSLocalizedString("渲染 Markdown", comment: ""), isOn: $enableMarkdown)
                if enableMarkdown {
                    Toggle(NSLocalizedString("使用高级渲染器", comment: ""), isOn: $enableAdvancedRenderer)
                }
                Toggle(NSLocalizedString("无气泡UI", comment: ""), isOn: $enableNoBubbleUI)
                Toggle(NSLocalizedString("自动预览思考过程", comment: ""), isOn: $enableAutoReasoningPreview)
                NavigationLink {
                    WatchChatAppearanceProfileSettingsView()
                } label: {
                    HStack {
                        Text(NSLocalizedString("颜色配置", comment: ""))
                        Spacer()
                        Text(String(format: NSLocalizedString("当前使用：%@", comment: ""), displaySettingsProfileDisplayName(appearanceProfileManager.activeProfile)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                NavigationLink {
                    WatchFontSettingsView()
                } label: {
                    Text(NSLocalizedString("字体设置", comment: ""))
                }
            }

            // MARK: Section 4：全局外观
            Section(header: Text(NSLocalizedString("全局外观", comment: ""))) {
                Picker(NSLocalizedString("App 语言", comment: ""), selection: appLanguageBinding) {
                    ForEach(AppLanguagePreference.allCases) { language in
                        appLanguageLabel(language)
                            .tag(language.rawValue)
                    }
                }
                Toggle(NSLocalizedString("彩色设置图标", comment: ""), isOn: colorfulSettingsIconsBinding)
                    .disabled(!canUseColorfulSettingsIcons)
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
