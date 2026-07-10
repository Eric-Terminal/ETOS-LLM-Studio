// ============================================================================
// DisplaySettingsViewSupport.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 显示设置视图的颜色配置、时间段规则与颜色编辑辅助界面。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

func displaySettingsProfileDisplayName(_ profile: ChatAppearanceProfile) -> String {
    if profile.isDefaultProfile && profile.name == ChatAppearanceProfile.defaultProfileID {
        return NSLocalizedString("默认配置", comment: "")
    }
    return profile.name
}

struct WatchChatAppearanceProfileSettingsView: View {
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
                        Text(displaySettingsProfileDisplayName(profile)).tag(profile.id)
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
                Text(String(format: NSLocalizedString("当前生效：%@", comment: ""), displaySettingsProfileDisplayName(manager.activeProfile)))
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
            var profile = selectedProfile
            profile.userBubble = .defaultUserBubble
            profile.assistantBubble = .defaultAssistantBubble
            profile.userLightText = .defaultUserLightText
            profile.assistantLightText = .defaultAssistantLightText
            profile.userLightTextStyles = ChatAppearanceTextStyleColors(
                defaultHex: ChatAppearanceColorSlot.defaultUserLightText.hex
            )
            profile.assistantLightTextStyles = ChatAppearanceTextStyleColors(
                defaultHex: ChatAppearanceColorSlot.defaultAssistantLightText.hex
            )
            try manager.updateProfile(profile)
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
            title: NSLocalizedString("用户气泡颜色", comment: "User bubble color title"),
            toggleTitle: NSLocalizedString("自定义用户气泡颜色", comment: "Custom user bubble color toggle"),
            slot: userBubbleBinding,
            fallback: defaultUserBubbleColor,
            description: NSLocalizedString("影响你发送消息的气泡背景颜色。", comment: "User bubble color description")
        )
        colorSlotEditor(
            title: NSLocalizedString("助手气泡颜色", comment: "Assistant bubble color title"),
            toggleTitle: NSLocalizedString("自定义助手气泡颜色（含 Tool）", comment: "Custom assistant bubble color toggle"),
            slot: assistantBubbleBinding,
            fallback: defaultAssistantBubbleColor,
            description: NSLocalizedString("影响助手消息与 Tool 消息的气泡背景颜色。", comment: "Assistant bubble color description")
        )
        textStyleColorsLink(
            title: NSLocalizedString("用户文字样式", comment: "User text styles title"),
            bodyColor: userLightTextBinding,
            styleColors: userLightTextStylesBinding,
            fallback: .white
        )
        textStyleColorsLink(
            title: NSLocalizedString("助手文字样式", comment: "Assistant text styles title"),
            bodyColor: assistantLightTextBinding,
            styleColors: assistantLightTextStylesBinding,
            fallback: .init(.sRGB, red: 0.11, green: 0.11, blue: 0.12, opacity: 1)
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

    private var userLightTextBinding: Binding<ChatAppearanceColorSlot> {
        slotBinding(\.userLightText)
    }

    private var assistantLightTextBinding: Binding<ChatAppearanceColorSlot> {
        slotBinding(\.assistantLightText)
    }

    private var userLightTextStylesBinding: Binding<ChatAppearanceTextStyleColors> {
        textStylesBinding(\.userLightTextStyles)
    }

    private var assistantLightTextStylesBinding: Binding<ChatAppearanceTextStyleColors> {
        textStylesBinding(\.assistantLightTextStyles)
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

    private func textStylesBinding(
        _ keyPath: WritableKeyPath<ChatAppearanceProfile, ChatAppearanceTextStyleColors>
    ) -> Binding<ChatAppearanceTextStyleColors> {
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
    private func textStyleColorsLink(
        title: String,
        bodyColor: Binding<ChatAppearanceColorSlot>,
        styleColors: Binding<ChatAppearanceTextStyleColors>,
        fallback: Color
    ) -> some View {
        NavigationLink {
            WatchTextStyleColorSettingsView(
                title: title,
                bodyColor: bodyColor,
                styleColors: styleColors,
                fallback: fallback
            )
        } label: {
            Text(title)
        }
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
                    Text(displaySettingsProfileDisplayName(profile)).tag(profile.id)
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
}

struct WatchColorEditorView: View {
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
                channelSlider(title: NSLocalizedString("红", comment: "Red color channel"), value: $red, tint: .red)
                channelSlider(title: NSLocalizedString("绿", comment: "Green color channel"), value: $green, tint: .green)
                channelSlider(title: NSLocalizedString("蓝", comment: "Blue color channel"), value: $blue, tint: .blue)
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
