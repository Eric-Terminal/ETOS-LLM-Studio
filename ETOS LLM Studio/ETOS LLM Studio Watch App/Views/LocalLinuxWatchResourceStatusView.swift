// ============================================================================
// LocalLinuxWatchResourceStatusView.swift
// ============================================================================
// 本地 Linux 只展示设备资源压力，不据此施加产品配额。
// ============================================================================

import ETOSCore
import SwiftUI

struct LocalLinuxWatchResourceStatusView: View {
    @ObservedObject private var monitor = LocalResourceUsageMonitor.shared

    var body: some View {
        Section {
            Text(monitor.snapshot.displayText)
                .font(.caption2)
            LabeledContent(
                NSLocalizedString("温度", comment: "Watch local Linux thermal state"),
                value: monitor.snapshot.thermalCondition.displayName
            )
        } header: {
            Text(NSLocalizedString("资源", comment: "Watch local Linux resources"))
        } footer: {
            Text(NSLocalizedString("只提示资源与温度，不限制任务数量。", comment: "Watch local Linux resources footer"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                await monitor.refresh()
                try? await Task<Never, Never>.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
