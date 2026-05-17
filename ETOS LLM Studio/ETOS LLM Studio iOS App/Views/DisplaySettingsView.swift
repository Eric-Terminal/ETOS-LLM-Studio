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

struct DisplaySettingsView: View {
    @Binding var enableMarkdown: Bool
    @Binding var enableBackground: Bool
    @Binding var backgroundBlur: Double
    @Binding var backgroundOpacity: Double
    @Binding var enableAutoRotateBackground: Bool
    @Binding var currentBackgroundImage: String
    @Binding var backgroundContentMode: String
    @Binding var enableLiquidGlass: Bool
    @Binding var enableChatTopBlurFade: Bool
    @Binding var enableAdvancedRenderer: Bool
    @Binding var enableAutoReasoningPreview: Bool
    @Binding var enableNoBubbleUI: Bool

    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var appearanceProfileManager = ChatAppearanceProfileManager.shared

    let allBackgrounds: [String]

    var body: some View {
        TabView {
            // MARK: - Tab 1：沉浸背景
            Form {
                Section(NSLocalizedString("背景图层", comment: "")) {
                    Toggle(NSLocalizedString("显示背景", comment: ""), isOn: $enableBackground)

                    if enableBackground {
                        NavigationLink {
                            BackgroundPickerView(allBackgrounds: allBackgrounds, selectedBackground: $currentBackgroundImage)
                        } label: {
                            Label(NSLocalizedString("选择背景图", comment: ""), systemImage: "photo.on.rectangle")
                        }

                        Picker(NSLocalizedString("填充模式", comment: ""), selection: $backgroundContentMode) {
                            Text(NSLocalizedString("填充 (居中裁剪)", comment: "")).tag("fill")
                            Text(NSLocalizedString("适应 (完整显示)", comment: "")).tag("fit")
                        }

                        Toggle(NSLocalizedString("自动轮换背景", comment: ""), isOn: $enableAutoRotateBackground)
                    }
                }

                if enableBackground {
                    Section(NSLocalizedString("质感与特效", comment: "")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(format: NSLocalizedString("模糊 %.1f", comment: ""), backgroundBlur))
                            Slider(value: $backgroundBlur, in: 0...25, step: 0.5)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(format: NSLocalizedString("不透明度 %.2f", comment: ""), backgroundOpacity))
                            Slider(value: $backgroundOpacity, in: 0.1...1.0, step: 0.05)
                        }

                        if #available(iOS 26.0, *) {
                            Toggle(NSLocalizedString("液态玻璃效果", comment: ""), isOn: $enableLiquidGlass)
                        }
                    }
                }
            }
            .tabItem {
                Label(NSLocalizedString("沉浸背景", comment: ""), systemImage: "photo.fill")
            }

            // MARK: - Tab 2：对话框视觉
            Form {
                Section(NSLocalizedString("气泡与排版", comment: "")) {
                    Toggle(NSLocalizedString("渲染 Markdown", comment: ""), isOn: $enableMarkdown)
                    if enableMarkdown {
                        Toggle(NSLocalizedString("使用高级渲染器", comment: ""), isOn: $enableAdvancedRenderer)
                    }
                    Toggle(NSLocalizedString("无气泡UI", comment: ""), isOn: $enableNoBubbleUI)
                    Toggle(NSLocalizedString("顶部毛玻璃渐隐", comment: ""), isOn: $enableChatTopBlurFade)
                }

                Section {
                    NavigationLink {
                        ChatAppearanceProfileSettingsView()
                    } label: {
                        Label(NSLocalizedString("颜色配置", comment: ""), systemImage: "paintpalette")
                    }
                } header: {
                    Text(NSLocalizedString("个性化色彩", comment: ""))
                } footer: {
                    Text(String(format: NSLocalizedString("当前使用：%@", comment: ""), displaySettingsProfileDisplayName(appearanceProfileManager.activeProfile)))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        FontSettingsView()
                    } label: {
                        Label(NSLocalizedString("字体设置", comment: ""), systemImage: "textformat.alt")
                    }
                } header: {
                    Text(NSLocalizedString("字体排印", comment: ""))
                }

                Section {
                    Toggle(NSLocalizedString("自动预览思考过程", comment: ""), isOn: $enableAutoReasoningPreview)
                } header: {
                    Text(NSLocalizedString("思考过程展现", comment: ""))
                } footer: {
                    Text(NSLocalizedString("开启后，AI 回复仅有思考内容时会自动展开；一旦出现正文会自动收起。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem {
                Label(NSLocalizedString("对话框视觉", comment: ""), systemImage: "bubble.left")
            }
            .onChange(of: enableMarkdown) { _, isEnabled in
                if !isEnabled, enableAdvancedRenderer {
                    enableAdvancedRenderer = false
                }
            }

            // MARK: - Tab 3：气泡功能栏
            MessageActionBarSettingsView()
            .tabItem {
                Label(NSLocalizedString("功能栏", comment: ""), systemImage: "ellipsis.rectangle")
            }

            // MARK: - Tab 4：界面与交互
            Form {
                Section(footer: Text(NSLocalizedString("设定呼出菜单的呈现方式。「悬浮面板」带来视觉聚焦的居中体验；「底部抽屉」则顺应自然的拇指手势，让每一次切换都如丝般顺滑。", comment: ""))) {
                    Picker(NSLocalizedString("会话/模型弹出方式", comment: ""), selection: chatPickerPresentationStyleBinding) {
                        Text(NSLocalizedString("悬浮面板", comment: "")).tag(ChatPickerPresentationStyle.legacyOverlay)
                        Text(NSLocalizedString("底部抽屉", comment: "")).tag(ChatPickerPresentationStyle.bottomSheet)
                    }
                }

                Section {
                    Picker(NSLocalizedString("App 语言", comment: ""), selection: appLanguageBinding) {
                        ForEach(AppLanguagePreference.allCases) { language in
                            appLanguageLabel(language)
                                .tag(language.rawValue)
                        }
                    }
                    Toggle(NSLocalizedString("彩色设置图标", comment: ""), isOn: $appConfig.settingsColorfulIconsEnabled)
                } header: {
                    Text(NSLocalizedString("全局外观", comment: ""))
                } footer: {
                    Text(NSLocalizedString("手动选择 App 界面语言；开启彩色图标后，设置入口会使用彩色圆形图标。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem {
                Label(NSLocalizedString("界面与交互", comment: ""), systemImage: "slider.horizontal.3")
            }
        }
        .navigationTitle(NSLocalizedString("显示设置", comment: ""))
        .onAppear {
            // 迁移：将旧版「悬浮面板」默认值更新为「底部抽屉」
            let hasMigratedPickerStyle = AppConfigStore.boolValue(
                for: .chatPickerStyleMigratedToBottomSheet,
                legacyUserDefaultsKey: "chatPickerStyleMigratedToBottomSheet"
            )
            if ChatPickerPresentationStyle.resolvedStyle(rawValue: appConfig.chatPickerPresentationStyle) == .legacyOverlay,
               !hasMigratedPickerStyle {
                appConfig.chatPickerPresentationStyle = ChatPickerPresentationStyle.bottomSheet.rawValue
                AppConfigStore.persistSynchronously(.bool(true), for: .chatPickerStyleMigratedToBottomSheet)
            }
        }
    }

    private var chatPickerPresentationStyleBinding: Binding<ChatPickerPresentationStyle> {
        Binding(
            get: { ChatPickerPresentationStyle.resolvedStyle(rawValue: appConfig.chatPickerPresentationStyle) },
            set: { appConfig.chatPickerPresentationStyle = $0.rawValue }
        )
    }

    private var appLanguageBinding: Binding<String> {
        Binding(
            get: { appConfig.appLanguage },
            set: { newValue in
                appConfig.appLanguage = newValue
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
