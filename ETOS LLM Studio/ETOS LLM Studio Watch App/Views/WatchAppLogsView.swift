// ============================================================================
// WatchAppLogsView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 功能特性:
// - 查看用户操作日志和开发者日志
// - 支持按通道清空日志
// ============================================================================

import SwiftUI
import Shared

struct WatchAppLogsView: View {
    @StateObject private var logCenter = AppLogCenter.shared
    @State private var selectedChannel: AppLogChannel = .user

    var body: some View {
        List {
            Section {
                Picker("日志类型", selection: $selectedChannel) {
                    Text("用户").tag(AppLogChannel.user)
                    Text("开发").tag(AppLogChannel.developer)
                }
            }

            Section {
                if displayedLogs.isEmpty {
                    Text("暂无日志")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedLogs) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.level.displayName)
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(levelColor(entry.level))
                                Spacer()
                                Text(formatTime(entry.timestamp))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Text("\(entry.category) · \(entry.action)")
                                .font(.caption2)
                                .lineLimit(2)

                            Text(entry.message)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            if let payload = entry.payload, !payload.isEmpty {
                                Text(formatPayload(payload))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(4)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                Button("清空当前日志") {
                    logCenter.clear(channel: selectedChannel)
                }
                .disabled(displayedLogs.isEmpty)
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("应用日志")
    }

    private var displayedLogs: [AppLogEvent] {
        Array(logCenter.recentLogs(for: selectedChannel, limit: 150).reversed())
    }

    private func levelColor(_ level: AppLogLevel) -> Color {
        switch level {
        case .debug:
            return .gray
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        @unknown default:
            return .gray
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private func formatPayload(_ payload: [String: String]) -> String {
        let sorted = payload.sorted { $0.key < $1.key }
        return sorted.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}
