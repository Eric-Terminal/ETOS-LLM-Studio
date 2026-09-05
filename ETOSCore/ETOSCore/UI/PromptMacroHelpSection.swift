import SwiftUI

/// 在各提示词入口复用静态说明，设备状态只在发送请求时采集。
public struct PromptMacroHelpSection: View {
    #if os(watchOS)
    @State private var showsMacros = false
    #endif

    public init() {}

    public var body: some View {
        Section {
            settingsIntroCard

            #if os(watchOS)
            // watchOS 没有 DisclosureGroup，使用独立按钮行控制下方内容，避免整段说明参与点击。
            Button {
                showsMacros.toggle()
            } label: {
                HStack {
                    Text(NSLocalizedString("查看可用宏", value: "Available macros", comment: "展开提示词宏列表"))
                    Spacer()
                    Image(systemName: showsMacros ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if showsMacros {
                macroList
            }
            #else
            DisclosureGroup(NSLocalizedString("查看可用宏", value: "Available macros", comment: "展开提示词宏列表")) {
                macroList
            }
            #endif
        } header: {
            Text(NSLocalizedString("提示词宏", value: "Prompt macros", comment: "提示词宏帮助标题"))
        } footer: {
            Text(NSLocalizedString(
                "提示词宏缓存说明",
                value: "Changing values may reduce cache reuse from their position onward. Enhancement prompts are placed at the end. You choose where to use macros; actual caching depends on the provider and API format.",
                comment: "动态宏位置与缓存效果，使用位置由用户选择"
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var macroList: some View {
        Text(NSLocalizedString(
            "提示词宏语法说明",
            value: "Macro names are case-insensitive and may have surrounding spaces. Single braces, {name}, also expand. Unknown macros stay unchanged. Values come from the device sending the request; unavailable readings return unknown.",
            comment: "提示词宏语法和取值边界"
        ))
        .font(.footnote)
        .foregroundStyle(.secondary)

        macroGroup(
            NSLocalizedString("日期与时间", value: "Date and time", comment: "提示词宏分组"),
            description: NSLocalizedString(
                "提示词宏时间列表",
                value: "{{cur_date}} — local date (yyyy-MM-dd)\n{{cur_time}} — local time (HH:mm:ss)\n{{cur_datetime}} — local date and time\n{{utc_datetime}} — UTC time in ISO 8601\n{{weekday}} — day of the week\n{{timestamp}} — Unix timestamp in seconds\n{{timezone}} — time zone ID\n{{timezone_offset}} — UTC offset, such as +08:00",
                comment: "时间宏及格式"
            )
        )
        macroGroup(
            NSLocalizedString("模型与供应商", value: "Model and provider", comment: "提示词宏分组"),
            description: NSLocalizedString(
                "提示词宏模型列表",
                value: "{{model_id}} — API model ID\n{{model_name}} — model display name\n{{provider_id}} — provider ID\n{{provider_name}} — provider name\n{{api_format}} — API format used by this request",
                comment: "模型宏使用本轮实际选中的模型"
            )
        )
        macroGroup(
            NSLocalizedString("称呼与会话", value: "Names and conversation", comment: "提示词宏分组"),
            description: NSLocalizedString(
                "提示词宏会话列表",
                value: "{{nickname}} / {{user}} — current or default Persona name; User if unset\n{{char}} / {{assistant_name}} — character name; model name if unset\n{{chat_id}} — conversation ID\n{{chat_name}} — conversation name\n{{message_count}} — number of user and assistant messages prepared for this request",
                comment: "称呼宏来源和会话宏"
            )
        )
        macroGroup(
            NSLocalizedString("语言与应用", value: "Language and app", comment: "提示词宏分组"),
            description: NSLocalizedString(
                "提示词宏应用列表",
                value: "{{locale}} — app locale ID\n{{language}} — app language name\n{{system_locale}} — system locale ID\n{{app_name}} — app name\n{{app_version}} — app version\n{{app_build}} — build number",
                comment: "语言与应用版本宏"
            )
        )
        macroGroup(
            NSLocalizedString("设备信息", value: "Device information", comment: "提示词宏分组"),
            description: NSLocalizedString(
                "提示词宏设备列表",
                value: "{{platform}} — platform, such as iOS or watchOS\n{{system_version}} — platform and OS version\n{{device_info}} — device type and model ID\n{{device_model}} — hardware model ID\n{{device_name}} — device name provided by the system",
                comment: "当前发送设备的系统与硬件宏"
            )
        )
        macroGroup(
            NSLocalizedString("电量与运行状态", value: "Battery and system status", comment: "提示词宏分组"),
            description: NSLocalizedString(
                "提示词宏状态列表",
                value: "{{battery_level}} — battery percentage, 0–100 without %\n{{battery_state}} — unplugged, charging, full or unknown\n{{is_charging}} — true, false or unknown; full means false\n{{low_power_mode}} — low power mode, true or false\n{{thermal_state}} — nominal, fair, serious, critical or unknown\n{{system_uptime}} — time since boot in seconds\nBattery readings are collected only when referenced, without background polling.",
                comment: "电量宏单位、状态枚举与按需采集说明"
            )
        )
    }

    private var settingsIntroCard: some View {
        VStack(alignment: .leading) {
            Text(NSLocalizedString(
                "提示词宏使用说明",
                value: "System prompts, conversation system prompts, topic prompts, enhancement prompts and chat input all support macros. Saved prompts and user messages keep their original text. Macros are evaluated again for every request, including those in historical user messages sent with it.",
                comment: "提示词宏使用教程"
            ))
            Text(NSLocalizedString(
                "提示词宏双三括号说明",
                value: "Double braces read the current value. Triple braces send the literal macro text without expanding it. For example, when the battery is at 90%:",
                comment: "双括号展开、三括号字面量的规则与示例前言"
            ))
            Text(NSLocalizedString(
                "提示词宏展开示例",
                value: "{{battery_level}} → 90\n{{{battery_level}}} → {{battery_level}}",
                comment: "输入语法与发送结果，保留括号层数"
            ))
            .monospaced()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func macroGroup(_ title: String, description: String) -> some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.footnote.weight(.semibold))
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
