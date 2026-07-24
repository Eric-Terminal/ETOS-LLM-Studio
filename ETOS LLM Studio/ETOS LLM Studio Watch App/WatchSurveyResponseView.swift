// ============================================================================
// WatchSurveyResponseView.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 意见征集弹窗，复用手表端结构化问答交互。
// ============================================================================

import ETOSCore
import SwiftUI

struct WatchSurveyResponseView: View {
    let survey: SurveyDefinition
    @ObservedObject var manager: SurveyManager

    var body: some View {
        WatchAskUserInputView(
            request: survey.inputRequest,
            privacyNotice: NSLocalizedString(
                "匿名提交",
                comment: "Survey anonymous submission note"
            ),
            navigationTitle: NSLocalizedString("意见征集", comment: "Survey navigation title"),
            dismissesAfterSubmit: false,
            onSubmit: { answers in
                Task {
                    await manager.submit(answers)
                }
            },
            onCancel: {
                manager.dismissCurrentSurvey()
            }
        )
        .allowsHitTesting(!manager.isSubmitting)
        .overlay {
            if manager.isSubmitting {
                ProgressView()
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .alert(
            NSLocalizedString("提交失败", comment: "Survey submission failure title"),
            isPresented: Binding(
                get: { manager.submissionErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        manager.clearSubmissionError()
                    }
                }
            )
        ) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {
                manager.clearSubmissionError()
            }
        } message: {
            Text(manager.submissionErrorMessage ?? "")
        }
    }
}
