// ============================================================================
// SurveyResponseSheet.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 意见征集弹窗，复用应用内结构化问答交互。
// ============================================================================

import ETOSCore
import SwiftUI

struct SurveyResponseSheet: View {
    let survey: SurveyDefinition
    @ObservedObject var manager: SurveyManager

    var body: some View {
        VStack(spacing: 12) {
            Label(
                NSLocalizedString("匿名提交", comment: "Survey anonymous submission note"),
                systemImage: "hand.raised.slash"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            AskUserInputComposerPanel(
                request: survey.inputRequest,
                submitAction: { answers in
                    Task {
                        await manager.submit(answers)
                    }
                },
                cancelAction: {
                    manager.dismissCurrentSurvey()
                }
            )
            .allowsHitTesting(!manager.isSubmitting)

            if manager.isSubmitting {
                ProgressView(NSLocalizedString("正在提交…", comment: "Survey submission progress"))
                    .font(.footnote)
            } else if let message = manager.submissionErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .interactiveDismissDisabled(manager.isSubmitting)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
