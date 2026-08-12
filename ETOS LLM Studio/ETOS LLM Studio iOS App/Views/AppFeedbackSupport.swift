// ============================================================================
// AppFeedbackSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 统一承载 iOS 离散操作的触觉反馈与短暂完成状态。
// ============================================================================

import SwiftUI
import UIKit

@MainActor
enum AppHapticFeedback {
    static func operationSucceeded() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

struct CopyConfirmationButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: (_ didCopy: Bool) -> Label

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            action()
            AppHapticFeedback.operationSucceeded()

            resetTask?.cancel()
            withAnimation(.easeInOut(duration: 0.15)) {
                didCopy = true
            }
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    didCopy = false
                }
            }
        } label: {
            label(didCopy)
        }
        .onDisappear {
            resetTask?.cancel()
            didCopy = false
        }
    }
}
