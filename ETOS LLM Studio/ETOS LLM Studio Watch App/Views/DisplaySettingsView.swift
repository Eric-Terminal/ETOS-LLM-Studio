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
                Text(String(format: NSLocalizedString("当前使用：%@", comment: ""), profileDisplayName(appearanceProfileManager.activeProfile)))
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

    private func profileDisplayName(_ profile: ChatAppearanceProfile) -> String {
        if profile.isDefaultProfile && profile.name == ChatAppearanceProfile.defaultProfileID {
            return NSLocalizedString("默认配置", comment: "")
        }
        return profile.name
    }
}

private struct WatchChatAppearanceProfileSettingsView: View {
    @ObservedObject private var manager = ChatAppearanceProfileManager.shared
    @State private var selectedProfileID = ChatAppearanceProfile.defaultProfileID
    @State private var errorMessage: String?

    private var selectedProfile: ChatAppearanceProfile {
        manager.configuration.profile(id: selectedProfileID) ?? manager.configuration.defaultProfile
    }

    var body: some View {
        Form {
            Section {
                Picker(NSLocalizedString("当前编辑", comment: ""), selection: selectedProfileIDBinding) {
                    ForEach(manager.configuration.profiles) { profile in
                        Text(profileDisplayName(profile)).tag(profile.id)
                    }
                }

                Button {
                    addProfile()
                } label: {
                    Label(NSLocalizedString("新增颜色配置", comment: ""), systemImage: "plus")
                }
            } header: {
                Text(NSLocalizedString("配置", comment: ""))
            } footer: {
                Text(String(format: NSLocalizedString("当前生效：%@", comment: ""), profileDisplayName(manager.activeProfile)))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                WatchChatAppearanceProfileEditor(profile: selectedProfile) { updatedProfile in
                    saveProfile(updatedProfile)
                }

                Button(NSLocalizedString("恢复默认聊天颜色", comment: "")) {
                    resetColors()
                }

                if !selectedProfile.isDefaultProfile {
                    Button(NSLocalizedString("删除配置", comment: ""), role: .destructive) {
                        deleteSelectedProfile()
                    }
                }
            } header: {
                Text(NSLocalizedString("颜色", comment: ""))
            }

            Section {
                ForEach(manager.configuration.scheduleRules) { rule in
                    WatchScheduleRuleRow(
                        rule: rule,
                        profiles: manager.configuration.profiles
                    ) { updatedRule in
                        saveRule(updatedRule)
                    } onDelete: {
                        deleteRule(rule.id)
                    }
                }

                Button {
                    addRule()
                } label: {
                    Label(NSLocalizedString("新增时间段", comment: ""), systemImage: "clock.badge.plus")
                }
            } header: {
                Text(NSLocalizedString("自动切换", comment: ""))
            } footer: {
                Text(NSLocalizedString("没有匹配时间段时会使用默认配置；时间段不能重叠。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("颜色配置", comment: ""))
        .alert(NSLocalizedString("颜色配置", comment: ""), isPresented: errorPresented) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            manager.activate()
            selectedProfileID = selectedProfile.id
        }
        .onChange(of: manager.configuration.profiles) { _, profiles in
            if !profiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = manager.configuration.defaultProfile.id
            }
        }
    }

    private var selectedProfileIDBinding: Binding<String> {
        Binding(
            get: { selectedProfileID },
            set: { selectedProfileID = $0 }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func addProfile() {
        do {
            let profile = try manager.addProfile()
            selectedProfileID = profile.id
        } catch {
            show(error)
        }
    }

    private func saveProfile(_ profile: ChatAppearanceProfile) {
        do {
            try manager.updateProfile(profile)
            selectedProfileID = profile.id
        } catch {
            show(error)
        }
    }

    private func resetColors() {
        do {
            try manager.resetColors(profileID: selectedProfileID)
        } catch {
            show(error)
        }
    }

    private func deleteSelectedProfile() {
        do {
            let deletingID = selectedProfileID
            selectedProfileID = ChatAppearanceProfile.defaultProfileID
            try manager.deleteProfile(id: deletingID)
        } catch {
            show(error)
        }
    }

    private func addRule() {
        do {
            guard let window = manager.configuration.firstAvailableScheduleWindow() else {
                throw ChatAppearanceProfileError.noAvailableScheduleWindow
            }
            _ = try manager.addScheduleRule(
                profileID: selectedProfileID,
                startMinuteOfDay: window.startMinuteOfDay,
                endMinuteOfDay: window.endMinuteOfDay
            )
        } catch {
            show(error)
        }
    }

    private func saveRule(_ rule: ChatAppearanceScheduleRule) {
        do {
            try manager.updateScheduleRule(rule)
        } catch {
            show(error)
        }
    }

    private func deleteRule(_ id: String) {
        do {
            try manager.deleteScheduleRule(id: id)
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func profileDisplayName(_ profile: ChatAppearanceProfile) -> String {
        if profile.isDefaultProfile && profile.name == ChatAppearanceProfile.defaultProfileID {
            return NSLocalizedString("默认配置", comment: "")
        }
        return profile.name
    }
}

private struct WatchChatAppearanceProfileEditor: View {
    let profile: ChatAppearanceProfile
    let onChange: (ChatAppearanceProfile) -> Void

    private var defaultUserBubbleColor: Color {
        .init(.sRGB, red: 0.24, green: 0.56, blue: 0.95, opacity: 1)
    }

    private var defaultAssistantBubbleColor: Color {
        .init(.sRGB, red: 0.949, green: 0.949, blue: 0.969, opacity: 1)
    }

    var body: some View {
        TextField(NSLocalizedString("配置名称", comment: ""), text: nameBinding)

        colorSlotEditor(
            title: "用户气泡颜色",
            toggleTitle: "自定义用户气泡颜色",
            slot: userBubbleBinding,
            fallback: defaultUserBubbleColor,
            description: "影响你发送消息的气泡背景颜色。"
        )
        colorSlotEditor(
            title: "助手气泡颜色",
            toggleTitle: "自定义助手气泡颜色（含 Tool）",
            slot: assistantBubbleBinding,
            fallback: defaultAssistantBubbleColor,
            description: "影响助手消息与 Tool 消息的气泡背景颜色。"
        )
        colorSlotEditor(
            title: "白天文字颜色",
            toggleTitle: "自定义白天文字颜色",
            slot: lightTextBinding,
            fallback: .init(.sRGB, red: 0.11, green: 0.11, blue: 0.12, opacity: 1),
            description: "覆盖浅色外观下的聊天文本颜色。"
        )
        colorSlotEditor(
            title: "夜览文字颜色",
            toggleTitle: "自定义夜览文字颜色",
            slot: darkTextBinding,
            fallback: .white,
            description: "覆盖深色外观下的聊天文本颜色。"
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { profileEditableName(profile) },
            set: { newValue in
                var updated = profile
                updated.name = newValue
                onChange(updated)
            }
        )
    }

    private func profileEditableName(_ profile: ChatAppearanceProfile) -> String {
        if profile.isDefaultProfile && profile.name == ChatAppearanceProfile.defaultProfileID {
            return NSLocalizedString("默认配置", comment: "")
        }
        return profile.name
    }

    private var userBubbleBinding: Binding<ChatAppearanceColorSlot> {
        slotBinding(\.userBubble)
    }

    private var assistantBubbleBinding: Binding<ChatAppearanceColorSlot> {
        slotBinding(\.assistantBubble)
    }

    private var lightTextBinding: Binding<ChatAppearanceColorSlot> {
        slotBinding(\.lightText)
    }

    private var darkTextBinding: Binding<ChatAppearanceColorSlot> {
        slotBinding(\.darkText)
    }

    private func slotBinding(_ keyPath: WritableKeyPath<ChatAppearanceProfile, ChatAppearanceColorSlot>) -> Binding<ChatAppearanceColorSlot> {
        Binding(
            get: { profile[keyPath: keyPath] },
            set: { newValue in
                var updated = profile
                updated[keyPath: keyPath] = newValue
                onChange(updated)
            }
        )
    }

    @ViewBuilder
    private func colorSlotEditor(
        title: String,
        toggleTitle: String,
        slot: Binding<ChatAppearanceColorSlot>,
        fallback: Color,
        description: String
    ) -> some View {
        Toggle(NSLocalizedString(toggleTitle, comment: ""), isOn: Binding(
            get: { slot.wrappedValue.isEnabled },
            set: { isEnabled in
                var updated = slot.wrappedValue
                updated.isEnabled = isEnabled
                slot.wrappedValue = updated
            }
        ))

        if slot.wrappedValue.isEnabled {
            colorEditorLink(
                title: title,
                hex: Binding(
                    get: { slot.wrappedValue.hex },
                    set: { newValue in
                        var updated = slot.wrappedValue
                        updated.hex = newValue
                        slot.wrappedValue = updated
                    }
                ),
                fallback: fallback,
                description: description
            )
        }
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
}

private struct WatchScheduleRuleRow: View {
    let rule: ChatAppearanceScheduleRule
    let profiles: [ChatAppearanceProfile]
    let onChange: (ChatAppearanceScheduleRule) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rule.displayTimeRange)
                .etFont(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Picker(NSLocalizedString("使用配置", comment: ""), selection: profileIDBinding) {
                ForEach(profiles) { profile in
                    Text(profileDisplayName(profile)).tag(profile.id)
                }
            }

            DatePicker(
                NSLocalizedString("开始时间", comment: ""),
                selection: startDateBinding,
                displayedComponents: .hourAndMinute
            )

            DatePicker(
                NSLocalizedString("结束时间", comment: ""),
                selection: endDateBinding,
                displayedComponents: .hourAndMinute
            )

            Button(NSLocalizedString("删除时间段", comment: ""), role: .destructive) {
                onDelete()
            }
        }
    }

    private var profileIDBinding: Binding<String> {
        Binding(
            get: { rule.profileID },
            set: { newValue in
                var updated = rule
                updated.profileID = newValue
                onChange(updated)
            }
        )
    }

    private var startDateBinding: Binding<Date> {
        minuteDateBinding(
            get: { rule.startMinuteOfDay },
            set: { newMinute in
                var updated = rule
                updated.startMinuteOfDay = newMinute
                onChange(updated)
            }
        )
    }

    private var endDateBinding: Binding<Date> {
        minuteDateBinding(
            get: { rule.endMinuteOfDay },
            set: { newMinute in
                var updated = rule
                updated.endMinuteOfDay = newMinute
                onChange(updated)
            }
        )
    }

    private func minuteDateBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: { date(fromMinute: get()) },
            set: { set(ChatAppearanceProfileConfiguration.minuteOfDay(for: $0)) }
        )
    }

    private func date(fromMinute minute: Int) -> Date {
        let normalized = ChatAppearanceScheduleRule.normalizedMinute(minute)
        return Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(TimeInterval(normalized * 60))
    }

    private func profileDisplayName(_ profile: ChatAppearanceProfile) -> String {
        if profile.isDefaultProfile && profile.name == ChatAppearanceProfile.defaultProfileID {
            return NSLocalizedString("默认配置", comment: "")
        }
        return profile.name
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
                Text(NSLocalizedString(description, comment: "颜色编辑说明"))
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
                Text(NSLocalizedString("RGB", comment: ""))
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
        .navigationTitle(NSLocalizedString(title, comment: "颜色编辑标题"))
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
                Text(NSLocalizedString(title, comment: "颜色通道标题"))
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
