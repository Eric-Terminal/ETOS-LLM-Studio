// ============================================================================
// ModelConfigurationIntroCard.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 在小屏上保留简短说明，将完整模型配置教程放入独立详情页。
// ============================================================================

import SwiftUI

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
            ScrollView {
                Text(NSLocalizedString("模型配置介绍正文", comment: "模型配置介绍卡片详情"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}
