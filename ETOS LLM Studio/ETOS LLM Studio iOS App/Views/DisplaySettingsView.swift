// ============================================================================
// DisplaySettingsView.swift
// ============================================================================
// DisplaySettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

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

                if enableBackground && selectedBackgroundIsVideo {
                    Section {
                        Toggle(
                            NSLocalizedString("离开聊天时继续播放", comment: "Video background continuous playback toggle"),
                            isOn: $appConfig.continueVideoBackgroundPlaybackWhenChatHidden
                        )
                    } footer: {
                        Text(NSLocalizedString("开启后，进入设置等页面时视频会继续播放，返回聊天时保持原有进度；App 进入后台后仍会暂停。", comment: "Video background continuous playback description"))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
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
                            if enableLiquidGlass {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(NSLocalizedString("玻璃底色不透明度", comment: ""))
                                        Spacer(minLength: 8)
                                        Text(
                                            String(
                                                format: NSLocalizedString("%.0f%%", comment: ""),
                                                liquidGlassTintOpacityBinding.wrappedValue * 100
                                            )
                                        )
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                    Slider(
                                        value: liquidGlassTintOpacityBinding,
                                        in: LiquidGlassTintSetting.minimumOpacity...LiquidGlassTintSetting.maximumOpacity,
                                        step: LiquidGlassTintSetting.opacityStep
                                    )
                                }

                                Button(NSLocalizedString("恢复默认玻璃底色", comment: "")) {
                                    liquidGlassTintOpacityBinding.wrappedValue = LiquidGlassTintSetting.defaultOpacity
                                }
                                .disabled(
                                    abs(
                                        liquidGlassTintOpacityBinding.wrappedValue
                                            - LiquidGlassTintSetting.defaultOpacity
                                    ) < 0.001
                                )
                            }
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
                    Toggle(NSLocalizedString("关闭助手气泡", comment: ""), isOn: $enableNoBubbleUI)
                    Toggle(NSLocalizedString("顶部毛玻璃渐隐", comment: ""), isOn: $enableChatTopBlurFade)
                }

                Section {
                    Toggle(
                        NSLocalizedString("四键消息导航", comment: "Chat timeline navigation toggle"),
                        isOn: $appConfig.chatTimelineNavigationEnabled
                    )
                } header: {
                    Text(NSLocalizedString("聊天导航", comment: "Chat navigation settings section"))
                } footer: {
                    Text(NSLocalizedString("开启后，从聊天区右侧向左轻扫可展开四个导航按钮，停止操作后会自动收起；关闭后仍保留原有的回到底部按钮。", comment: "Chat timeline navigation description"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker(
                        NSLocalizedString("流式显示", comment: "Streaming response display mode"),
                        selection: $appConfig.chatStreamingDisplayMode
                    ) {
                        ForEach(ChatStreamingDisplayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("流式显示", comment: "Streaming response display section"))
                } footer: {
                    Text(NSLocalizedString("即时模式优先响应速度，并让新增文字快速淡入；柔和模式会合并更多流式分片，以更舒缓的节奏显示新增文字。", comment: "Streaming response display mode description"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        ChatAnimationSettingsView()
                    } label: {
                        HStack {
                            Label(NSLocalizedString("聊天动画", comment: ""), systemImage: "sparkles")
                            Spacer()
                            Text(
                                isAnyChatAnimationEnabled
                                    ? NSLocalizedString("已启用", comment: "")
                                    : NSLocalizedString("已停用", comment: "")
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
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
                    Toggle(NSLocalizedString("响应式思考预览高度", comment: ""), isOn: $appConfig.enableResponsiveReasoningPreviewHeight)

                    if !appConfig.enableResponsiveReasoningPreviewHeight {
                        HStack {
                            Text(NSLocalizedString("预览高度百分比", comment: ""))
                            Spacer()
                            TextField(
                                NSLocalizedString("百分比", comment: ""),
                                value: $appConfig.reasoningPreviewHeightPercent,
                                formatter: percentageFormatter
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 82)
                            Text("%")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("思考过程展现", comment: ""))
                } footer: {
                    Text(NSLocalizedString("自动预览会在 AI 回复仅有思考内容时展开，一旦出现正文会收起。关闭响应式高度后，预览框会按你填写的聊天区高度百分比直接计算。", comment: ""))
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
                Section {
                    Picker(NSLocalizedString("App 语言", comment: ""), selection: appLanguageBinding) {
                        ForEach(AppLanguagePreference.allCases) { language in
                            appLanguageLabel(language)
                                .tag(language.rawValue)
                        }
                    }
                    Toggle(NSLocalizedString("彩色设置图标", comment: ""), isOn: $appConfig.settingsColorfulIconsEnabled)

                    NavigationLink {
                        AppIconSettingsView()
                    } label: {
                        Label(NSLocalizedString("主屏幕图标", comment: "自定义主屏幕图标设置入口"), systemImage: "app.fill")
                    }
                } header: {
                    Text(NSLocalizedString("全局外观", comment: ""))
                } footer: {
                    Text(NSLocalizedString("手动选择 App 界面语言；开启彩色图标后，设置入口会使用彩色圆形图标；主屏幕图标可使用你自己的图片。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker(NSLocalizedString("输入栏样式", comment: "聊天输入栏样式选择器"), selection: chatComposerStyleBinding) {
                        ForEach(ChatComposerStyle.allCases) { style in
                            Text(chatComposerStyleTitle(style))
                                .tag(style)
                        }
                    }

                    NavigationLink {
                        ChatQuickActionSettingsView()
                    } label: {
                        SettingsListIconLabel("聊天快捷功能", icon: .chatQuickAction)
                    }
                } header: {
                    Text(NSLocalizedString("聊天界面", comment: "设置聊天界面分组"))
                } footer: {
                    Text(NSLocalizedString("胶囊样式保持紧凑；卡片样式会将附件、请求控制、语音和发送操作收进同一输入区域，并随文本自然增高。", comment: "聊天输入栏样式说明"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(
                        NSLocalizedString("按 Return 发送消息", comment: "实体键盘 Return 发送设置"),
                        isOn: $appConfig.iOSHardwareKeyboardReturnSendsMessage
                    )
                } header: {
                    Text(NSLocalizedString("实体键盘", comment: "实体键盘设置分组"))
                } footer: {
                    Text(NSLocalizedString("开启后，按 Return 发送消息，按 Shift–Return 换行。关闭后，按 ⌘Return 发送。屏幕键盘不受影响。", comment: "实体键盘 Return 行为说明"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem {
                Label(NSLocalizedString("界面与交互", comment: ""), systemImage: "slider.horizontal.3")
            }
        }
        .navigationTitle(NSLocalizedString("显示设置", comment: ""))
        .guideSettingsPageContext(
            id: "settings-display",
            title: NSLocalizedString("显示设置", comment: "显示设置向导上下文标题"),
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
            settings: guideSettings
        )
    }

    private var guideSettings: [GuidePageSetting] {
        [
            .bool("background_enabled", label: NSLocalizedString("显示背景", comment: "向导设置字段"), get: { enableBackground }, set: { enableBackground = $0 }),
            .readOnly("current_background", label: NSLocalizedString("当前背景图", comment: "向导设置字段"), value: { .string(currentBackgroundImage) }),
            .string("background_content_mode", label: NSLocalizedString("背景填充模式", comment: "向导设置字段"), allowedValues: ["fill", "fit"], get: { backgroundContentMode }, set: { backgroundContentMode = $0 }),
            .bool("background_auto_rotation", label: NSLocalizedString("自动轮换背景", comment: "向导设置字段"), get: { enableAutoRotateBackground }, set: { enableAutoRotateBackground = $0 }),
            .double("background_blur", label: NSLocalizedString("背景模糊", comment: "向导设置字段"), range: 0...25, get: { backgroundBlur }, set: { backgroundBlur = $0 }),
            .double("background_opacity", label: NSLocalizedString("背景不透明度", comment: "向导设置字段"), range: 0.1...1, get: { backgroundOpacity }, set: { backgroundOpacity = $0 }),
            .bool("video_background_continues_when_hidden", label: NSLocalizedString("离开聊天时继续播放视频背景", comment: "向导设置字段"), get: { appConfig.continueVideoBackgroundPlaybackWhenChatHidden }, set: { appConfig.continueVideoBackgroundPlaybackWhenChatHidden = $0 }),
            .bool("liquid_glass", label: NSLocalizedString("液态玻璃效果", comment: "向导设置字段"), get: { enableLiquidGlass }, set: { enableLiquidGlass = $0 }),
            .double("liquid_glass_tint_opacity", label: NSLocalizedString("玻璃底色不透明度", comment: "向导设置字段"), range: LiquidGlassTintSetting.minimumOpacity...LiquidGlassTintSetting.maximumOpacity, get: { liquidGlassTintOpacityBinding.wrappedValue }, set: { liquidGlassTintOpacityBinding.wrappedValue = $0 }),
            .bool("markdown_rendering", label: NSLocalizedString("渲染 Markdown", comment: "向导设置字段"), get: { enableMarkdown }, set: { enableMarkdown = $0 }),
            .bool("advanced_renderer", label: NSLocalizedString("使用高级渲染器", comment: "向导设置字段"), get: { enableAdvancedRenderer }, set: { enableAdvancedRenderer = $0 }),
            .bool("hide_assistant_bubble", label: NSLocalizedString("关闭助手气泡", comment: "向导设置字段"), get: { enableNoBubbleUI }, set: { enableNoBubbleUI = $0 }),
            .bool("chat_top_blur_fade", label: NSLocalizedString("顶部毛玻璃渐隐", comment: "向导设置字段"), get: { enableChatTopBlurFade }, set: { enableChatTopBlurFade = $0 }),
            .bool("timeline_navigation", label: NSLocalizedString("四键消息导航", comment: "向导设置字段"), get: { appConfig.chatTimelineNavigationEnabled }, set: { appConfig.chatTimelineNavigationEnabled = $0 }),
            .string("streaming_display_mode", label: NSLocalizedString("流式显示模式", comment: "向导设置字段"), allowedValues: ChatStreamingDisplayMode.allCases.map(\.rawValue), get: { appConfig.chatStreamingDisplayMode }, set: { appConfig.chatStreamingDisplayMode = $0 }),
            .bool("auto_reasoning_preview", label: NSLocalizedString("自动预览思考过程", comment: "向导设置字段"), get: { enableAutoReasoningPreview }, set: { enableAutoReasoningPreview = $0 }),
            .bool("responsive_reasoning_preview_height", label: NSLocalizedString("响应式思考预览高度", comment: "向导设置字段"), get: { appConfig.enableResponsiveReasoningPreviewHeight }, set: { appConfig.enableResponsiveReasoningPreviewHeight = $0 }),
            .double("reasoning_preview_height_percent", label: NSLocalizedString("思考预览高度百分比", comment: "向导设置字段"), range: 1...100, get: { appConfig.reasoningPreviewHeightPercent }, set: { appConfig.reasoningPreviewHeightPercent = $0 }),
            .string("app_language", label: NSLocalizedString("App 语言", comment: "向导设置字段"), allowedValues: AppLanguagePreference.allCases.map(\.rawValue), get: { appConfig.appLanguage }, set: { appLanguageBinding.wrappedValue = $0 }),
            .bool("colorful_settings_icons", label: NSLocalizedString("彩色设置图标", comment: "向导设置字段"), get: { appConfig.settingsColorfulIconsEnabled }, set: { appConfig.settingsColorfulIconsEnabled = $0 }),
            .string("chat_composer_style", label: NSLocalizedString("输入栏样式", comment: "向导设置字段"), allowedValues: ChatComposerStyle.allCases.map(\.rawValue), get: { ChatComposerStyle.normalized(appConfig.chatComposerStyle).rawValue }, set: { appConfig.chatComposerStyle = $0 }),
            .bool("hardware_return_sends_message", label: NSLocalizedString("按 Return 发送消息", comment: "向导设置字段"), get: { appConfig.iOSHardwareKeyboardReturnSendsMessage }, set: { appConfig.iOSHardwareKeyboardReturnSendsMessage = $0 })
        ]
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

    private var liquidGlassTintOpacityBinding: Binding<Double> {
        Binding(
            get: { LiquidGlassTintSetting.normalized(appConfig.liquidGlassTintOpacity) },
            set: { appConfig.liquidGlassTintOpacity = LiquidGlassTintSetting.normalized($0) }
        )
    }

    private var chatComposerStyleBinding: Binding<ChatComposerStyle> {
        Binding(
            get: { ChatComposerStyle.normalized(appConfig.chatComposerStyle) },
            set: { appConfig.chatComposerStyle = $0.rawValue }
        )
    }

    private func chatComposerStyleTitle(_ style: ChatComposerStyle) -> String {
        switch style {
        case .capsule:
            return NSLocalizedString("胶囊", comment: "胶囊聊天输入栏样式")
        case .card:
            return NSLocalizedString("卡片", comment: "卡片聊天输入栏样式")
        }
    }

    private var isAnyChatAnimationEnabled: Bool {
        appConfig.chatScrollAnimationEnabled || appConfig.chatSendAnimationEnabled
    }

    private var selectedBackgroundIsVideo: Bool {
        ConfigLoader.isVideoBackgroundFile(currentBackgroundImage)
    }

    @ViewBuilder
    private func appLanguageLabel(_ language: AppLanguagePreference) -> some View {
        if language == .system {
            Text(NSLocalizedString("跟随系统", comment: ""))
        } else {
            Text(language.nativeDisplayName)
        }
    }

    private var percentageFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.allowsFloats = true
        return formatter
    }
}
