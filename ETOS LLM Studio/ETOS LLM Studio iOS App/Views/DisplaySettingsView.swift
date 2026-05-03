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

    @AppStorage(ChatPickerPresentationStyle.storageKey) private var chatPickerPresentationStyleRawValue: String = ChatPickerPresentationStyle.defaultStyle.rawValue
    @AppStorage(SettingsIconAppearancePreference.storageKey) private var useColorfulSettingsIcons: Bool = true
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguageRawValue: String = AppLanguagePreference.defaultLanguage.rawValue
    @ObservedObject private var appearanceProfileManager = ChatAppearanceProfileManager.shared

    let allBackgrounds: [String]

    var body: some View {
        Form {
            Section(NSLocalizedString("背景", comment: "")) {
                Toggle(NSLocalizedString("显示背景", comment: ""), isOn: $enableBackground)

                if enableBackground {
                    Picker(NSLocalizedString("填充模式", comment: ""), selection: $backgroundContentMode) {
                        Text(NSLocalizedString("填充 (居中裁剪)", comment: "")).tag("fill")
                        Text(NSLocalizedString("适应 (完整显示)", comment: "")).tag("fit")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("模糊 %.1f", comment: ""), backgroundBlur))
                        Slider(value: $backgroundBlur, in: 0...25, step: 0.5)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("不透明度 %.2f", comment: ""), backgroundOpacity))
                        Slider(value: $backgroundOpacity, in: 0.1...1.0, step: 0.05)
                    }

                    Toggle(NSLocalizedString("自动轮换背景", comment: ""), isOn: $enableAutoRotateBackground)

                    NavigationLink {
                        BackgroundPickerView(allBackgrounds: allBackgrounds, selectedBackground: $currentBackgroundImage)
                    } label: {
                        Label(NSLocalizedString("选择背景图", comment: ""), systemImage: "photo.on.rectangle")
                    }
                }
            }

            Section {
                Toggle(NSLocalizedString("渲染 Markdown", comment: ""), isOn: $enableMarkdown)
                if enableMarkdown {
                    Toggle(NSLocalizedString("使用高级渲染器", comment: ""), isOn: $enableAdvancedRenderer)
                }
            } header: {
                Text(NSLocalizedString("内容表现", comment: ""))
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

            Section(footer: Text(NSLocalizedString("设定呼出菜单的呈现方式。「悬浮面板」带来视觉聚焦的居中体验；「底部抽屉」则顺应自然的拇指手势，让每一次切换都如丝般顺滑。", comment: ""))) {
                Picker(NSLocalizedString("会话/模型弹出方式", comment: ""), selection: chatPickerPresentationStyleBinding) {
                    Text(NSLocalizedString("悬浮面板", comment: "")).tag(ChatPickerPresentationStyle.legacyOverlay)
                    Text(NSLocalizedString("底部抽屉", comment: "")).tag(ChatPickerPresentationStyle.bottomSheet)
                }
            }

            Section {
                Toggle(NSLocalizedString("彩色设置图标", comment: ""), isOn: $useColorfulSettingsIcons)
            } footer: {
                Text(NSLocalizedString("开启后，设置入口会使用彩色圆形图标；关闭后恢复单色线条图标。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    FontSettingsView()
                } label: {
                    Label(NSLocalizedString("字体设置", comment: ""), systemImage: "textformat.alt")
                }
            }

            Section {
                Toggle(NSLocalizedString("无气泡UI", comment: ""), isOn: $enableNoBubbleUI)
                Toggle(NSLocalizedString("顶部毛玻璃渐隐", comment: ""), isOn: $enableChatTopBlurFade)
            } footer: {
                Text(NSLocalizedString("无气泡UI会透明化聊天气泡并放宽消息文本宽度；顶部毛玻璃渐隐会让聊天页顶部向消息区自然过渡。", comment: ""))
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

            if #available(iOS 26.0, *) {
                Section {
                    Toggle(NSLocalizedString("液态玻璃效果", comment: ""), isOn: $enableLiquidGlass)
                }
            }

            Section {
                NavigationLink {
                    ChatAppearanceProfileSettingsView()
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
    }

    private var chatPickerPresentationStyleBinding: Binding<ChatPickerPresentationStyle> {
        Binding(
            get: { ChatPickerPresentationStyle.resolvedStyle(rawValue: chatPickerPresentationStyleRawValue) },
            set: { chatPickerPresentationStyleRawValue = $0.rawValue }
        )
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
