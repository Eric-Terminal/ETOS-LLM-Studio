// ============================================================================
// AppLogsView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 功能特性:
// - 查看用户操作日志和开发者日志
// - 支持按通道清空日志
// - 支持复制当前通道最近日志
// ============================================================================

import SwiftUI
import Shared
#if canImport(UIKit)
import UIKit
#endif

struct AppLogsView: View {
    @StateObject private var logCenter = AppLogCenter.shared
    @State private var selectedChannel: AppLogChannel = .user
    @State private var keywordFilter: String = ""
    @State private var categoryFilter: String = ""
    @State private var levelFilter: LevelFilter = .all
    @State private var configChangesOnly = false

    var body: some View {
        List {
            Section {
                Picker("日志类型", selection: $selectedChannel) {
                    Text("用户").tag(AppLogChannel.user)
                    Text("开发者").tag(AppLogChannel.developer)
                }
                .pickerStyle(.segmented)
            }

            Section("筛选") {
                TextField("关键词（消息 / 动作 / payload）", text: $keywordFilter)
                    .textInputAutocapitalization(.never)
                TextField("分类（category）", text: $categoryFilter)
                    .textInputAutocapitalization(.never)

                Picker("等级", selection: $levelFilter) {
                    ForEach(LevelFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)

                Toggle("仅看配置变更", isOn: $configChangesOnly)

                if hasActiveFilters {
                    Button("重置筛选") {
                        keywordFilter = ""
                        categoryFilter = ""
                        levelFilter = .all
                        configChangesOnly = false
                    }
                }
            }

            Section(header: Text(selectedChannel.displayName)) {
                if displayedLogs.isEmpty {
                    ContentUnavailableView("暂无日志", systemImage: "doc.text", description: Text("执行操作后会在这里显示"))
                } else {
                    ForEach(displayedLogs) { entry in
                        AppLogRow(entry: entry)
                    }
                }
            }
        }
        .navigationTitle("应用日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("清空") {
                    logCenter.clear(channel: selectedChannel)
                }
                .disabled(displayedLogs.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("复制") {
                    copyLogsToClipboard()
                }
                .disabled(displayedLogs.isEmpty)
            }
        }
    }

    private var displayedLogs: [AppLogEvent] {
        let source = Array(logCenter.recentLogs(for: selectedChannel, limit: 300).reversed())
        let filter = AppLogFilter(
            level: levelFilter.level,
            keyword: keywordFilter,
            categoryKeyword: categoryFilter,
            configChangesOnly: configChangesOnly
        )
        return AppLogFilterEngine.filter(source, with: filter)
    }

    private var hasActiveFilters: Bool {
        !keywordFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !categoryFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        levelFilter != .all ||
        configChangesOnly
    }

    private func copyLogsToClipboard() {
        let content = displayedLogs
            .map { entry in
                var lines: [String] = [
                    "[\(formatTime(entry.timestamp))] [\(entry.level.displayName)] [\(entry.category)] [\(entry.action)] \(entry.message)"
                ]
                if let payload = entry.payload, !payload.isEmpty {
                    lines.append(formatPayload(payload))
                }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n\n")

        #if canImport(UIKit)
        UIPasteboard.general.string = content
        #endif
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

private enum LevelFilter: String, CaseIterable, Identifiable {
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

private struct AppLogRow: View {
    let entry: AppLogEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.level.displayName)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(levelColor.opacity(0.16))
                    .foregroundStyle(levelColor)
                    .clipShape(Capsule())

                Text("\(entry.category) · \(entry.action)")
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(formatTime(entry.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(entry.message)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let payload = entry.payload, !payload.isEmpty {
                Text(formatPayload(payload))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }
        }
        .padding(.vertical, 2)
    }

    private var levelColor: Color {
        switch entry.level {
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
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private func formatPayload(_ payload: [String: String]) -> String {
        let sorted = payload.sorted { $0.key < $1.key }
        return sorted.map { "\($0.key):\n\($0.value)" }.joined(separator: "\n\n")
    }
}
