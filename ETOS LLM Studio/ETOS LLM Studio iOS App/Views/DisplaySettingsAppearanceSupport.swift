// ============================================================================
// DisplaySettingsAppearanceSupport.swift
// ============================================================================
// DisplaySettingsView 的颜色配置支持视图
// - 负责聊天颜色配置、配置编辑与时间段自动切换
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

struct ChatAppearanceProfileSettingsView: View {
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
                ChatAppearanceProfileEditor(profile: selectedProfile) { updatedProfile in
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
                    ScheduleRuleRow(
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
}

struct ChatAppearanceProfileEditor: View {
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
            supportsOpacity: true,
            opacityTitle: NSLocalizedString("用户气泡不透明度", comment: "User bubble opacity title")
        )
        colorSlotEditor(
            title: NSLocalizedString("助手气泡颜色", comment: "Assistant bubble color title"),
            toggleTitle: NSLocalizedString("自定义助手气泡颜色（含 Tool）", comment: "Custom assistant bubble color toggle"),
            slot: assistantBubbleBinding,
            fallback: defaultAssistantBubbleColor,
            supportsOpacity: true,
            opacityTitle: NSLocalizedString("助手气泡不透明度", comment: "Assistant bubble opacity title")
        )
        colorSlotEditor(
            title: NSLocalizedString("白天文字颜色", comment: "Light appearance text color title"),
            toggleTitle: NSLocalizedString("自定义白天文字颜色", comment: "Custom light text color toggle"),
            slot: lightTextBinding,
            fallback: .init(.sRGB, red: 0.11, green: 0.11, blue: 0.12, opacity: 1),
            supportsOpacity: false
        )
        colorSlotEditor(
            title: NSLocalizedString("夜览文字颜色", comment: "Dark appearance text color title"),
            toggleTitle: NSLocalizedString("自定义夜览文字颜色", comment: "Custom dark text color toggle"),
            slot: darkTextBinding,
            fallback: .white,
            supportsOpacity: false
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { displaySettingsProfileDisplayName(profile) },
            set: { newValue in
                var updated = profile
                updated.name = newValue
                onChange(updated)
            }
        )
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
        supportsOpacity: Bool,
        opacityTitle: String? = nil
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
            ColorPicker(
                NSLocalizedString(title, comment: ""),
                selection: colorBinding(slot: slot, fallback: fallback),
                supportsOpacity: false
            )

            if supportsOpacity {
                bubbleOpacitySlider(
                    title: NSLocalizedString(opacityTitle ?? "", comment: ""),
                    opacity: opacityBinding(slot: slot, fallback: fallback)
                )
            }
        }
    }

    private func colorBinding(slot: Binding<ChatAppearanceColorSlot>, fallback: Color) -> Binding<Color> {
        Binding(
            get: { ChatAppearanceColorCodec.color(from: slot.wrappedValue.hex, fallback: fallback) },
            set: { newColor in
                let currentAlpha = colorOpacity(hex: slot.wrappedValue.hex, fallback: fallback)
                let adjustedColor = ChatAppearanceColorCodec.replacingAlpha(of: newColor, with: currentAlpha)
                guard let encoded = ChatAppearanceColorCodec.hexRGBA(from: adjustedColor) else { return }
                var updated = slot.wrappedValue
                updated.hex = encoded
                slot.wrappedValue = updated
            }
        )
    }

    private func opacityBinding(slot: Binding<ChatAppearanceColorSlot>, fallback: Color) -> Binding<Double> {
        Binding(
            get: { colorOpacity(hex: slot.wrappedValue.hex, fallback: fallback) },
            set: { newOpacity in
                let color = ChatAppearanceColorCodec.color(from: slot.wrappedValue.hex, fallback: fallback)
                let adjustedColor = ChatAppearanceColorCodec.replacingAlpha(of: color, with: newOpacity)
                guard let encoded = ChatAppearanceColorCodec.hexRGBA(from: adjustedColor) else { return }
                var updated = slot.wrappedValue
                updated.hex = encoded
                slot.wrappedValue = updated
            }
        )
    }

    private func colorOpacity(hex: String, fallback: Color) -> Double {
        let color = ChatAppearanceColorCodec.color(from: hex, fallback: fallback)
        return ChatAppearanceColorCodec.rgbaComponents(from: color)?.alpha ?? 1
    }

    @ViewBuilder
    private func bubbleOpacitySlider(title: String, opacity: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text("\(Int((opacity.wrappedValue * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: opacity, in: 0...1, step: 0.05)
        }
    }
}

struct ScheduleRuleRow: View {
    let rule: ChatAppearanceScheduleRule
    let profiles: [ChatAppearanceProfile]
    let onChange: (ChatAppearanceScheduleRule) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
