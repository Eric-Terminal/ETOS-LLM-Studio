// ============================================================================
// LaunchSessionSettingsRows.swift
// ============================================================================
// iOS 启动会话策略设置行。
// ============================================================================

import SwiftUI
import ETOSCore

struct LaunchSessionSettingsRows: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var restoreWindowMinutesDraft = ""
    @FocusState private var isRestoreWindowFocused: Bool

    var body: some View {
        Group {
            Picker(NSLocalizedString("启动会话", comment: "Launch session behavior setting"), selection: behaviorBinding) {
                ForEach(LaunchSessionBehavior.allCases) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }

            if appConfig.launchSessionBehavior == .restoreIfRecent {
                LabeledContent(NSLocalizedString("恢复期限（分钟）", comment: "Recent session restore window in minutes")) {
                    TextField(
                        NSLocalizedString("分钟", comment: "Minutes placeholder"),
                        text: $restoreWindowMinutesDraft
                    )
                    .keyboardType(.numberPad)
                    .submitLabel(.done)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 80)
                    .focused($isRestoreWindowFocused)
                    .onSubmit {
                        commitRestoreWindowMinutesDraft()
                        isRestoreWindowFocused = false
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if isRestoreWindowFocused {
                    Spacer()
                    Button(NSLocalizedString("完成", comment: "Finish numeric input action")) {
                        commitRestoreWindowMinutesDraft()
                        isRestoreWindowFocused = false
                    }
                }
            }
        }
        .onAppear(perform: syncRestoreWindowMinutesDraft)
        .onChange(of: isRestoreWindowFocused) { oldValue, newValue in
            if oldValue && !newValue {
                commitRestoreWindowMinutesDraft()
            }
        }
        .onChange(of: appConfig.restoreLastSessionWithinMinutes) { _, _ in
            if !isRestoreWindowFocused {
                syncRestoreWindowMinutesDraft()
            }
        }
        .onChange(of: appConfig.launchSessionBehavior) { oldValue, newValue in
            if oldValue == .restoreIfRecent && newValue != .restoreIfRecent {
                commitRestoreWindowMinutesDraft()
                isRestoreWindowFocused = false
            } else if newValue == .restoreIfRecent {
                syncRestoreWindowMinutesDraft()
            }
        }
        .onDisappear(perform: commitRestoreWindowMinutesDraft)
    }

    private var behaviorBinding: Binding<LaunchSessionBehavior> {
        Binding(
            get: { appConfig.launchSessionBehavior },
            set: { appConfig.launchSessionBehavior = $0 }
        )
    }

    private func syncRestoreWindowMinutesDraft() {
        restoreWindowMinutesDraft = String(appConfig.restoreLastSessionWithinMinutes)
    }

    private func commitRestoreWindowMinutesDraft() {
        let resolvedMinutes = LaunchSessionPolicy.resolvedRestoreWindowMinutes(
            from: restoreWindowMinutesDraft,
            fallback: appConfig.restoreLastSessionWithinMinutes
        )
        if appConfig.restoreLastSessionWithinMinutes != resolvedMinutes {
            appConfig.restoreLastSessionWithinMinutes = resolvedMinutes
        }
        restoreWindowMinutesDraft = String(resolvedMinutes)
    }
}
