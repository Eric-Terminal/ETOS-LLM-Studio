// ============================================================================
// ModelConfigurationIntroCard.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 在小屏上保留简短说明，将完整模型配置教程放入独立详情页。
// ============================================================================

import SwiftUI
import ETOSCore

struct ModelConfigurationIntroCard: View {
    @State private var isShowingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("如何配置模型", comment: "模型配置介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString("先填写模型 ID 与用途；只有需要高级参数时，才配置自定义 Body 和结构化控制。", comment: "模型配置介绍卡片摘要"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isShowingDetails = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "模型配置介绍卡片展开按钮"))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: $isShowingDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading) {
                        Text(NSLocalizedString("模型配置介绍正文", comment: "模型配置介绍卡片详情"))
                            .etFont(.caption2)
                        Text(NSLocalizedString("model.prompt.help", value: "Add model-specific instructions in Model Settings → Model Prompt, then place {{model_prompt}} in a system, conversation, topic, or enhancement prompt—or right in the chat input. Each message inserts the active model’s prompt at that spot, or nothing if left blank. It is never added automatically, and macros inside it are not expanded again.", comment: "模型提示词宏完整教程"))
                            .etFont(.caption2)
                        Text(NSLocalizedString("Nested parameters and structured control merging", comment: "模型配置嵌套参数合并教程"))
                            .etFont(.caption2)
                        Text(NSLocalizedString("guide.controls.introduction", value: "Not sure how to write the parameters? Open the App Guide and describe the switch, preset group, or slider you want—such as a thinking budget or temperature control—then review and confirm its suggestion. Default values and the active selection in chat are separate, so mention if you want to switch the current selection too.", comment: "向导辅助结构化控制的使用说明"))
                            .etFont(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle(NSLocalizedString("如何配置模型", comment: "模型配置介绍详情标题"))
                .guideSettingsPageContext(
                    id: "watch-model-configuration-introduction",
                    title: NSLocalizedString("如何配置模型", comment: "模型配置介绍卡片详情标题"),
                    documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics"), GuideDocumentReference(id: "model-request-body", title: "Model Request Body")],
                    settings: [.readOnly("read_only", label: NSLocalizedString("如何配置模型", comment: "模型配置帮助页"), value: { .bool(true) })]
                )
                .watchGuideEntry()
            }
        }
    }
}
