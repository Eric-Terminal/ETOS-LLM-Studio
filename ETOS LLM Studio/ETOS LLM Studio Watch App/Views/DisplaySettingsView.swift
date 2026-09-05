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
import ETOSCore

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

    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var appearanceProfileManager = ChatAppearanceProfileManager.shared
    
    // MARK: - 属性
    
    let allBackgrounds: [String]
    
    // MARK: - 视图主体
    
    var body: some View {
        Form {
            // MARK: Section 1：背景与特效
            Section(header: Text(NSLocalizedString("背景与特效", comment: ""))) {
                Toggle(NSLocalizedString("显示背景", comment: ""), isOn: $enableBackground)
                if enableBackground {
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
            }

            if enableBackground && selectedBackgroundIsVideo {
                Section(
                    footer: Text(NSLocalizedString("开启后，进入设置等页面时视频会继续播放，返回聊天时保持原有进度；App 进入后台后仍会暂停。", comment: "Video background continuous playback description"))
                ) {
                    Toggle(
                        NSLocalizedString("离开聊天时继续播放", comment: "Video background continuous playback toggle"),
                        isOn: $appConfig.continueVideoBackgroundPlaybackWhenChatHidden
                    )
                }
            }

            // MARK: Section 2：对话框与内容
            Section(
                header: Text(NSLocalizedString("对话框与内容", comment: "")),
                footer: Text(NSLocalizedString("关闭响应式高度后，预览框会按你填写的聊天区高度百分比直接计算。", comment: ""))
            ) {
                Toggle(NSLocalizedString("渲染 Markdown", comment: ""), isOn: $enableMarkdown)
                if enableMarkdown {
                    Toggle(NSLocalizedString("使用高级渲染器", comment: ""), isOn: $enableAdvancedRenderer)
                }
                Toggle(NSLocalizedString("关闭助手气泡", comment: ""), isOn: $enableNoBubbleUI)
                Toggle(NSLocalizedString("自动预览思考过程", comment: ""), isOn: $enableAutoReasoningPreview)
                Toggle(NSLocalizedString("响应式思考预览高度", comment: ""), isOn: $appConfig.enableResponsiveReasoningPreviewHeight)
                if !appConfig.enableResponsiveReasoningPreviewHeight {
                    TextField(
                        NSLocalizedString("预览高度百分比", comment: ""),
                        value: $appConfig.reasoningPreviewHeightPercent,
                        formatter: percentageFormatter
                    )
                }
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

            Section {
                TextField(
                    NSLocalizedString("预览字符数", comment: "长用户消息预览设置"),
                    value: $appConfig.userMessagePreviewCharacterLimit,
                    format: .number.grouping(.never)
                )
                settingsIntroCard
            } header: {
                Text(NSLocalizedString("长用户消息", comment: "长用户消息设置分组"))
            } footer: {
                Text(NSLocalizedString("仅影响气泡显示；完整内容可在“更多”中查看。", comment: "长用户消息设置说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(
                header: Text(NSLocalizedString("流式显示", comment: "Streaming response display section")),
                footer: Text(NSLocalizedString("即时模式优先响应速度，并让新增文字快速淡入；柔和模式会合并更多流式分片，以更舒缓的节奏显示新增文字。", comment: "Streaming response display mode description"))
            ) {
                Picker(
                    NSLocalizedString("流式显示", comment: "Streaming response display mode"),
                    selection: $appConfig.chatStreamingDisplayMode
                ) {
                    ForEach(ChatStreamingDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
            }

            // MARK: Section 3：气泡功能栏
            Section(
                header: Text(NSLocalizedString("气泡功能栏", comment: "")),
                footer: Text(NSLocalizedString("助手气泡和用户气泡可以分别配置。", comment: ""))
            ) {
                NavigationLink {
                    WatchMessageActionBarSettingsView(role: .assistant)
                } label: {
                    Text(NSLocalizedString("助手气泡", comment: ""))
                }
                NavigationLink {
                    WatchMessageActionBarSettingsView(role: .user)
                } label: {
                    Text(NSLocalizedString("用户气泡", comment: ""))
                }
            }

            Section(header: Text(NSLocalizedString("界面与交互", comment: ""))) {
                NavigationLink {
                    WatchInputQuickActionSettingsView()
                } label: {
                    Text(NSLocalizedString("输入栏快捷功能", comment: "Watch input quick action settings entry"))
                }
            }

            // MARK: Section 4：全局外观
            Section(
                header: Text(NSLocalizedString("全局外观", comment: "")),
                footer: Text(NSLocalizedString("手动选择 App 界面语言；开启彩色图标后，设置入口会使用彩色圆形图标。", comment: ""))
            ) {
                Picker(NSLocalizedString("App 语言", comment: ""), selection: appLanguageBinding) {
                    ForEach(AppLanguagePreference.allCases) { language in
                        appLanguageLabel(language)
                            .tag(language.rawValue)
                    }
                }
                Toggle(NSLocalizedString("彩色设置图标", comment: ""), isOn: $appConfig.settingsColorfulIconsEnabled)
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
        }
        .guideSettingsPageContext(
            id: "settings-display",
            title: NSLocalizedString("显示设置", comment: "显示设置向导上下文标题"),
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
            settings: guideSettings
        )
        .watchGuideEntry()
    }

    private var guideSettings: [GuidePageSetting] {
        [
            GuideDisplaySettingsSupport.userMessagePreviewCharacterLimit(appConfig: appConfig),
            .bool("background_enabled", label: NSLocalizedString("显示背景", comment: "向导设置字段"), get: { enableBackground }, set: { enableBackground = $0 }),
            .readOnly("current_background", label: NSLocalizedString("当前背景图", comment: "向导设置字段"), value: { .string(currentBackgroundImage) }),
            .string("background_content_mode", label: NSLocalizedString("背景填充模式", comment: "向导设置字段"), allowedValues: ["fill", "fit"], get: { backgroundContentMode }, set: { backgroundContentMode = $0 }),
            .bool("background_auto_rotation", label: NSLocalizedString("背景随机轮换", comment: "向导设置字段"), get: { enableAutoRotateBackground }, set: { enableAutoRotateBackground = $0 }),
            .double("background_blur", label: NSLocalizedString("背景模糊", comment: "向导设置字段"), range: 0...25, get: { backgroundBlur }, set: { backgroundBlur = $0 }),
            .double("background_opacity", label: NSLocalizedString("背景不透明度", comment: "向导设置字段"), range: WatchBackgroundOpacitySetting.allowedRange, get: { backgroundOpacityBinding.wrappedValue }, set: { backgroundOpacityBinding.wrappedValue = $0 }),
            .bool("video_background_continues_when_hidden", label: NSLocalizedString("离开聊天时继续播放视频背景", comment: "向导设置字段"), get: { appConfig.continueVideoBackgroundPlaybackWhenChatHidden }, set: { appConfig.continueVideoBackgroundPlaybackWhenChatHidden = $0 }),
            .bool("liquid_glass", label: NSLocalizedString("启用液态玻璃", comment: "向导设置字段"), get: { enableLiquidGlass }, set: { enableLiquidGlass = $0 }),
            .bool("markdown_rendering", label: NSLocalizedString("渲染 Markdown", comment: "向导设置字段"), get: { enableMarkdown }, set: { enableMarkdown = $0 }),
            .bool("advanced_renderer", label: NSLocalizedString("使用高级渲染器", comment: "向导设置字段"), get: { enableAdvancedRenderer }, set: { enableAdvancedRenderer = $0 }),
            .bool("hide_assistant_bubble", label: NSLocalizedString("关闭助手气泡", comment: "向导设置字段"), get: { enableNoBubbleUI }, set: { enableNoBubbleUI = $0 }),
            .bool("auto_reasoning_preview", label: NSLocalizedString("自动预览思考过程", comment: "向导设置字段"), get: { enableAutoReasoningPreview }, set: { enableAutoReasoningPreview = $0 }),
            .bool("responsive_reasoning_preview_height", label: NSLocalizedString("响应式思考预览高度", comment: "向导设置字段"), get: { appConfig.enableResponsiveReasoningPreviewHeight }, set: { appConfig.enableResponsiveReasoningPreviewHeight = $0 }),
            .double("reasoning_preview_height_percent", label: NSLocalizedString("思考预览高度百分比", comment: "向导设置字段"), range: 1...100, get: { appConfig.reasoningPreviewHeightPercent }, set: { appConfig.reasoningPreviewHeightPercent = $0 }),
            .string("streaming_display_mode", label: NSLocalizedString("流式显示模式", comment: "向导设置字段"), allowedValues: ChatStreamingDisplayMode.allCases.map(\.rawValue), get: { appConfig.chatStreamingDisplayMode }, set: { appConfig.chatStreamingDisplayMode = $0 }),
            .string("app_language", label: NSLocalizedString("App 语言", comment: "向导设置字段"), allowedValues: AppLanguagePreference.allCases.map(\.rawValue), get: { appConfig.appLanguage }, set: { appLanguageBinding.wrappedValue = $0 }),
            .bool("colorful_settings_icons", label: NSLocalizedString("彩色设置图标", comment: "向导设置字段"), get: { appConfig.settingsColorfulIconsEnabled }, set: { appConfig.settingsColorfulIconsEnabled = $0 })
        ]
    }

    private var settingsIntroCard: some View {
        DisclosureGroup {
            Text(String(format: NSLocalizedString("超过设定字符数的用户消息会在气泡中截断，不限制行数。修改后会更新当前会话的预览，保存、发送给模型、复制和导出仍使用完整内容。默认值为 %ld 字符，可填写 1–100000。", comment: "长用户消息预览教程"), ChatUserMessagePreview.defaultCharacterLimit))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        } label: {
            Text(NSLocalizedString("进一步了解…", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
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

    private func normalizeBackgroundOpacityIfNeeded() {
        if normalizedBackgroundOpacity != backgroundOpacity {
            backgroundOpacity = normalizedBackgroundOpacity
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

    private var appLanguageBinding: Binding<String> {
        Binding(
            get: { appConfig.appLanguage },
            set: { newValue in
                appConfig.appLanguage = newValue
                AppLanguageRuntime.apply(rawValue: newValue)
            }
        )
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
}
