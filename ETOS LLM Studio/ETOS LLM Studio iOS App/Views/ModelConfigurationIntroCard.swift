// ============================================================================
// ModelConfigurationIntroCard.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 为模型配置页提供简短入口，并在详情页解释高级请求参数的工作方式。
// ============================================================================

import SwiftUI

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
                    Text(NSLocalizedString("模型配置介绍正文", comment: "模型配置介绍卡片详情"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString("如何配置模型", comment: "模型配置介绍卡片详情标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
