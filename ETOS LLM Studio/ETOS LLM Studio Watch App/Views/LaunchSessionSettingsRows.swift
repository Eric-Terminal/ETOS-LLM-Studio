// ============================================================================
// LaunchSessionSettingsRows.swift
// ============================================================================
// watchOS 启动会话策略设置行。
// ============================================================================

import SwiftUI
import ETOSCore

struct LaunchSessionSettingsRows: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var restoreWindowMinutesDraft = ""
    @State private var isEditingRestoreWindowMinutes = false

    var body: some View {
        Group {
            Picker(NSLocalizedString("启动会话", comment: "Launch session behavior setting"), selection: behaviorBinding) {
                ForEach(LaunchSessionBehavior.allCases) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }

            if appConfig.launchSessionBehavior == .restoreIfRecent {
                TextField(
                    NSLocalizedString("恢复期限（分钟）", comment: "Recent session restore window in minutes"),
                    text: $restoreWindowMinutesDraft,
                    onEditingChanged: { isEditing in
                        isEditingRestoreWindowMinutes = isEditing
                        if !isEditing {
                            commitRestoreWindowMinutesDraft()
                        }
                    },
                    onCommit: commitRestoreWindowMinutesDraft
                )
                .monospacedDigit()
            }
        }
        .onAppear(perform: syncRestoreWindowMinutesDraft)
        .onChange(of: appConfig.restoreLastSessionWithinMinutes) { _, _ in
            if !isEditingRestoreWindowMinutes {
                syncRestoreWindowMinutesDraft()
            }
        }
        .onChange(of: appConfig.launchSessionBehavior) { oldValue, newValue in
            if oldValue == .restoreIfRecent && newValue != .restoreIfRecent {
                commitRestoreWindowMinutesDraft()
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
        isEditingRestoreWindowMinutes = false
    }
}
