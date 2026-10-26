import SwiftUI

public enum GeminiInteractionsConfigurationHelp {
    public static var baseURLHint: String {
        NSLocalizedString(
            "Gemini Interactions API 地址说明",
            value: "Use a base URL such as https://generativelanguage.googleapis.com/v1. Requests use /interactions.",
            comment: "Interactions 提供商基础地址页脚"
        )
    }

    public static var details: String {
        NSLocalizedString(
            "Gemini Interactions 配置说明",
            value: "Select Gemini Interactions and enter your Gemini API key and a base URL ending in /v1. Keep an explicitly configured API version when your gateway requires it. Fetch the model list or add a supported model, enable its capabilities, then save. Existing Gemini configurations continue to use generateContent.\n\nChat history is sent from this device with store=false by default. Text, images, audio, documents, video and local function tools use the Interactions step format. Enable reasoning to add thinking_level and thinking_summaries controls under generation_config. Global temperature, top_p and top_k are not sent because the current API schema does not accept them.\n\nCustom JSON uses Interactions field names; generateContent parameters cannot be copied unchanged. This adapter handles foreground model requests, not managed agents, background jobs or previous_interaction_id chains. Image models use Interactions; embedding models still use Gemini's embedding endpoint.",
            comment: "Interactions 配置介绍卡教程"
        )
    }
}

/// 展开说明仍属于当前配置页，不创建缺少向导上下文的子页面。
public struct GeminiInteractionsSettingsIntroCard: View {
    @State private var isExpanded = false

    public init() {}

    public var body: some View {
        #if os(watchOS)
        VStack(alignment: .leading) {
            Button { isExpanded.toggle() } label: {
                Label(NSLocalizedString("使用说明", comment: ""), systemImage: isExpanded ? "chevron.up" : "info.circle")
            }
            .buttonStyle(.plain)
            if isExpanded { helpText }
        }
        #else
        DisclosureGroup(NSLocalizedString("使用说明", comment: ""), isExpanded: $isExpanded) {
            helpText
        }
        #endif
    }

    private var helpText: some View {
        Text(GeminiInteractionsConfigurationHelp.details).font(.footnote).foregroundStyle(.secondary)
    }
}
