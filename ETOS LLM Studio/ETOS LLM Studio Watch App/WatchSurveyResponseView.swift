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
    @State private var isCancellationConfirmationPresented = false
    @State private var hasConfirmedCancellation = false

    var body: some View {
        WatchAskUserInputView(
            request: survey.inputRequest,
            privacyNotice: NSLocalizedString(
                "匿名提交",
                comment: "Survey anonymous submission note"
            ),
            navigationTitle: NSLocalizedString("意见征集", comment: "Survey navigation title"),
            dismissesAfterSubmit: false,
            dismissesAfterCancel: false,
            onSubmit: { answers in
                Task {
                    await manager.submit(answers)
                }
            },
            onCancel: {
                guard !hasConfirmedCancellation else { return }
                isCancellationConfirmationPresented = true
            }
        )
        .allowsHitTesting(!manager.isSubmitting)
        .interactiveDismissDisabled(true)
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
                hasConfirmedCancellation = true
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
