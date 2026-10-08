import ETOSCore
import SwiftUI

struct MacTTSAdvancedFields: View {
    @ObservedObject var draft: MacTTSServiceDraft

    var body: some View {
        Section {
            if draft.fields.contains(.workspace) { TextField(NSLocalizedString("Workspace ID", comment: ""), text: $draft.advanced.workspaceID) }
            if draft.fields.contains(.region) { TextField(NSLocalizedString("区域", comment: ""), text: $draft.advanced.region) }
            if draft.fields.contains(.instruction) { TextField(NSLocalizedString("语音指令", comment: ""), text: $draft.advanced.instruction, axis: .vertical).lineLimit(2...6) }
            if draft.fields.contains(.speed) { Slider(value: $draft.advanced.speed, in: 0.5...2) { Text(NSLocalizedString("合成语速", comment: "")) } }
            if draft.fields.contains(.volume) { Slider(value: $draft.advanced.volume, in: 0...10) { Text(NSLocalizedString("合成音量", comment: "")) } }
            if draft.fields.contains(.pitch) { TextField(NSLocalizedString("合成音调", comment: ""), value: $draft.advanced.pitch, format: .number) }
            if draft.fields.contains(.sampleRate) { TextField(NSLocalizedString("采样率", comment: ""), value: $draft.advanced.sampleRate, format: .number) }
            if draft.fields.contains(.bitrate) { TextField(NSLocalizedString("比特率", comment: ""), value: $draft.advanced.bitrate, format: .number) }
            if draft.fields.contains(.channels) {
                Picker(NSLocalizedString("声道", comment: ""), selection: $draft.advanced.channels) {
                    Text(NSLocalizedString("单声道", comment: "")).tag(1)
                    Text(NSLocalizedString("立体声", comment: "")).tag(2)
                }
            }
            if draft.fields.contains(.languageBoost) { TextField(NSLocalizedString("语言增强", comment: ""), text: $draft.advanced.languageBoost) }
            if draft.fields.contains(.pronunciationDictionary) { TextField(NSLocalizedString("发音词典（每行一项）", comment: ""), text: $draft.pronunciationText, axis: .vertical).lineLimit(2...6) }
            if draft.fields.contains(.temperature) { Slider(value: $draft.advanced.temperature, in: 0...1) { Text(NSLocalizedString("随机性", comment: "")) } }
            if draft.fields.contains(.topP) { Slider(value: $draft.advanced.topP, in: 0...1) { Text(NSLocalizedString("Top P", comment: "")) } }
            if draft.fields.contains(.latency) {
                Picker(NSLocalizedString("延迟模式", comment: ""), selection: $draft.advanced.latency) {
                    Text(NSLocalizedString("标准", comment: "")).tag("normal")
                    Text(NSLocalizedString("均衡", comment: "")).tag("balanced")
                    Text(NSLocalizedString("低延迟", comment: "")).tag("low")
                }
            }
            if draft.fields.contains(.subtitles) { Toggle(NSLocalizedString("返回字幕", comment: ""), isOn: $draft.advanced.subtitleEnabled) }
            if draft.fields.contains(.optimizeTextPreview) { Toggle(NSLocalizedString("优化文本预览", comment: ""), isOn: $draft.advanced.optimizeTextPreview) }
        } header: { Text(NSLocalizedString("高级参数", comment: "")) } footer: {
            Text(NSLocalizedString("这些参数由当前语音服务定义；不确定时保持推荐值即可。", comment: "")).font(.footnote).foregroundStyle(.secondary)
        }
    }

    @MainActor
    static func guideSettings(_ draft: MacTTSServiceDraft) -> [GuidePageSetting] {
        var result: [GuidePageSetting] = []
        if draft.fields.contains(.workspace) { result.append(.string("workspace_id", label: NSLocalizedString("Workspace ID", comment: ""), get: { draft.advanced.workspaceID }, set: { draft.advanced.workspaceID = $0 })) }
        if draft.fields.contains(.region) { result.append(.string("region", label: NSLocalizedString("区域", comment: ""), get: { draft.advanced.region }, set: { draft.advanced.region = $0 })) }
        if draft.fields.contains(.instruction) { result.append(.string("instruction", label: NSLocalizedString("语音指令", comment: ""), get: { draft.advanced.instruction }, set: { draft.advanced.instruction = $0 })) }
        if draft.fields.contains(.speed) { result.append(.double("synthesis_speed", label: NSLocalizedString("合成语速", comment: ""), range: 0.5...2, get: { draft.advanced.speed }, set: { draft.advanced.speed = $0 })) }
        if draft.fields.contains(.volume) { result.append(.double("synthesis_volume", label: NSLocalizedString("合成音量", comment: ""), range: 0...10, get: { draft.advanced.volume }, set: { draft.advanced.volume = $0 })) }
        if draft.fields.contains(.pitch) { result.append(.integer("synthesis_pitch", label: NSLocalizedString("合成音调", comment: ""), range: -12...12, get: { draft.advanced.pitch }, set: { draft.advanced.pitch = $0 })) }
        if draft.fields.contains(.sampleRate) { result.append(.integer("sample_rate", label: NSLocalizedString("采样率", comment: ""), range: 8_000...48_000, get: { draft.advanced.sampleRate }, set: { draft.advanced.sampleRate = $0 })) }
        if draft.fields.contains(.bitrate) { result.append(.integer("bitrate", label: NSLocalizedString("比特率", comment: ""), range: 32_000...256_000, get: { draft.advanced.bitrate }, set: { draft.advanced.bitrate = $0 })) }
        if draft.fields.contains(.channels) { result.append(.integer("channels", label: NSLocalizedString("声道", comment: ""), range: 1...2, get: { draft.advanced.channels }, set: { draft.advanced.channels = $0 })) }
        if draft.fields.contains(.languageBoost) { result.append(.string("language_boost", label: NSLocalizedString("语言增强", comment: ""), get: { draft.advanced.languageBoost }, set: { draft.advanced.languageBoost = $0 })) }
        if draft.fields.contains(.pronunciationDictionary) { result.append(.string("pronunciation_dictionary", label: NSLocalizedString("发音词典（每行一项）", comment: ""), get: { draft.pronunciationText }, set: { draft.pronunciationText = $0 })) }
        if draft.fields.contains(.temperature) { result.append(.double("temperature", label: NSLocalizedString("随机性", comment: ""), range: 0...1, get: { draft.advanced.temperature }, set: { draft.advanced.temperature = $0 })) }
        if draft.fields.contains(.topP) { result.append(.double("top_p", label: NSLocalizedString("Top P", comment: ""), range: 0...1, get: { draft.advanced.topP }, set: { draft.advanced.topP = $0 })) }
        if draft.fields.contains(.latency) { result.append(.string("latency", label: NSLocalizedString("延迟模式", comment: ""), allowedValues: ["normal", "balanced", "low"], get: { draft.advanced.latency }, set: { draft.advanced.latency = $0 })) }
        if draft.fields.contains(.subtitles) { result.append(.bool("subtitles", label: NSLocalizedString("返回字幕", comment: ""), get: { draft.advanced.subtitleEnabled }, set: { draft.advanced.subtitleEnabled = $0 })) }
        if draft.fields.contains(.optimizeTextPreview) { result.append(.bool("optimize_text_preview", label: NSLocalizedString("优化文本预览", comment: ""), get: { draft.advanced.optimizeTextPreview }, set: { draft.advanced.optimizeTextPreview = $0 })) }
        return result
    }
}
