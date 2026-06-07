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

            // MARK: Section 2：对话框与内容
            Section(header: Text(NSLocalizedString("对话框与内容", comment: ""))) {
                Toggle(NSLocalizedString("渲染 Markdown", comment: ""), isOn: $enableMarkdown)
                if enableMarkdown {
                    Toggle(NSLocalizedString("使用高级渲染器", comment: ""), isOn: $enableAdvancedRenderer)
                }
                Toggle(NSLocalizedString("关闭助手气泡", comment: ""), isOn: $enableNoBubbleUI)
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
