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
    @State private var isCancellationConfirmationPresented = false

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
                    isCancellationConfirmationPresented = true
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
        .interactiveDismissDisabled(true)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .alert(
            NSLocalizedString("放弃此次作答？", comment: "Survey cancellation confirmation title"),
            isPresented: $isCancellationConfirmationPresented
        ) {
            Button(
                NSLocalizedString("继续作答", comment: "Continue answering survey"),
                role: .cancel
            ) {}
            Button(
                NSLocalizedString("放弃并不再显示", comment: "Permanently dismiss survey"),
                role: .destructive
            ) {
                manager.dismissCurrentSurvey()
            }
        } message: {
            Text(
                NSLocalizedString(
                    "关闭后，这份意见征集不会再次自动显示。",
                    comment: "Survey cancellation consequence"
                )
            )
        }
    }
}
