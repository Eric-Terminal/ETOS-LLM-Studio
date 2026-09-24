// ============================================================================
// ModelConfigurationIntroCard.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 为模型配置页提供简短入口，并在详情页解释高级请求参数的工作方式。
// ============================================================================

import SwiftUI
import ETOSCore

struct ModelConfigurationIntroCard: View {
    @State private var isShowingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("如何配置模型", comment: "模型配置介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString("先填写模型 ID 与用途；只有需要高级参数时，才配置自定义 Body 和结构化控制。", comment: "模型配置介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isShowingDetails = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "模型配置介绍卡片展开按钮"))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: $isShowingDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading) {
                        Text(NSLocalizedString("模型配置介绍正文", comment: "模型配置介绍卡片详情"))
                            .etFont(.footnote)
                        Text(NSLocalizedString("model.prompt.help", value: "Write model-specific instructions in Model settings → Model prompt, then place {{model_prompt}} in a system, conversation, topic or enhancement prompt, or chat input. Each request inserts the selected model's text at that position; an empty value inserts nothing. The text is not added automatically and macros inside it are not recursively expanded.", comment: "模型提示词宏完整教程"))
                            .etFont(.footnote)
                        Text(NSLocalizedString("Nested parameters and structured control merging", comment: "模型配置嵌套参数合并教程"))
                            .etFont(.footnote)
                        Text(NSLocalizedString("guide.controls.introduction", value: "You can ask the page guide to create a switch, preset group or slider for request parameters such as reasoning budgets, temperature or custom JSON. Explain what you want, then review and confirm the proposed changes. Defaults and the current chat selection are separate; say whether you also want to switch the current value. Available parameters depend on your provider and model.", comment: "向导辅助结构化控制的使用说明"))
                            .etFont(.footnote)
                    }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString("如何配置模型", comment: "模型配置介绍卡片详情标题"))
                .navigationBarTitleDisplayMode(.inline)
                .guideSettingsPageContext(
                    id: "model-configuration-introduction",
                    title: NSLocalizedString("如何配置模型", comment: "模型配置介绍卡片详情标题"),
                    documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics"), GuideDocumentReference(id: "model-request-body", title: "Model Request Body")],
                    settings: [.readOnly("read_only", label: NSLocalizedString("如何配置模型", comment: "模型配置帮助页"), value: { .bool(true) })]
                )
            }
        }
    }
}
