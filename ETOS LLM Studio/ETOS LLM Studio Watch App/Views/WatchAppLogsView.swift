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
    @State private var keywordFilter: String = ""
    @State private var categoryFilter: String = ""
    @State private var levelFilter: WatchLevelFilter = .all
    @State private var configChangesOnly = false

    var body: some View {
        List {
            Section {
                Picker("日志类型", selection: $selectedChannel) {
                    Text("用户").tag(AppLogChannel.user)
                    Text("开发").tag(AppLogChannel.developer)
                }
            }

            Section("筛选") {
                TextField("关键词", text: $keywordFilter)
                    .textInputAutocapitalization(.never)

                TextField("分类", text: $categoryFilter)
                    .textInputAutocapitalization(.never)

                Picker("等级", selection: $levelFilter) {
                    ForEach(WatchLevelFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }

                Toggle("仅看配置", isOn: $configChangesOnly)
            }

            Section {
                if displayedLogs.isEmpty {
                    Text("暂无日志")
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedLogs) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.level.displayName)
                                    .etFont(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(levelColor(entry.level))
                                Spacer()
                                Text(formatTime(entry.timestamp))
                                    .etFont(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Text("\(entry.category) · \(entry.action)")
                                .etFont(.caption2)
                                .lineLimit(2)

                            Text(entry.message)
                                .etFont(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            if let payload = entry.payload, !payload.isEmpty {
                                Text(formatPayload(payload))
                                    .etFont(.system(size: 9, design: .monospaced))
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
        let source = Array(logCenter.recentLogs(for: selectedChannel, limit: 150).reversed())
        let filter = AppLogFilter(
            level: levelFilter.level,
            keyword: keywordFilter,
            categoryKeyword: categoryFilter,
            configChangesOnly: configChangesOnly
        )
        return AppLogFilterEngine.filter(source, with: filter)
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

private enum WatchLevelFilter: String, CaseIterable, Identifiable {
    case all
    case debug
    case info
    case warning
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .warning:
            return "WARN"
        case .error:
            return "ERROR"
        }
    }

    var level: AppLogLevel? {
        switch self {
        case .all:
            return nil
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }
}
