// ============================================================================
// WatchAppLogsView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 功能特性:
// - 以“日期文件夹 -> 运行日志文件”层级查看日志
// - 用户/开发日志统一展示
// - 支持查看单次运行的详细日志
// ============================================================================

import SwiftUI
import Shared

struct WatchAppLogsView: View {
    @StateObject private var logCenter = AppLogCenter.shared
    @State private var showClearAllConfirm = false

    var body: some View {
        List {
            if logCenter.logDayFolders.isEmpty {
                Text(NSLocalizedString("暂无日志目录", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(logCenter.logDayFolders) { dayFolder in
                    NavigationLink {
                        WatchAppLogDayRunsView(logCenter: logCenter, dayFolderID: dayFolder.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dayFolder.day)
                                .etFont(.headline)
                            Text("\(dayFolder.runs.count) 个文件 · \(dayFolder.totalEventCount) 条")
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                            logCenter.deleteDayFolder(dayFolder)
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("应用日志", comment: ""))
        .task {
            await logCenter.refreshLogFolders()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showClearAllConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(logCenter.logDayFolders.isEmpty)
            }
        }
        .confirmationDialog(NSLocalizedString("确认清空所有日志？", comment: ""),
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("清空所有日志", comment: ""), role: .destructive) {
                logCenter.clearAll()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("该操作不可撤销。", comment: ""))
        }
    }
}

private struct WatchAppLogDayRunsView: View {
    @ObservedObject var logCenter: AppLogCenter
    let dayFolderID: String

    private var dayFolder: AppLogDayFolder? {
        logCenter.logDayFolders.first(where: { $0.id == dayFolderID })
    }

    var body: some View {
        List {
            if let dayFolder {
                ForEach(dayFolder.runs) { runFile in
                    NavigationLink {
                        WatchAppRunLogDetailView(logCenter: logCenter, runFile: runFile)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(runFile.fileName)
                                .etFont(.caption2)
                                .lineLimit(1)
                            Text("\(formatTime(runFile.createdAt)) · \(runFile.totalEventCount) 条")
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                            logCenter.deleteRunFile(runFile)
                        }
                    }
                }
            } else {
                Text(NSLocalizedString("目录已更新，请返回重进。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(dayFolderID)
    }
}

private struct WatchAppRunLogDetailView: View {
    @ObservedObject var logCenter: AppLogCenter
    let runFile: AppLogRunFile

    @State private var events: [AppLogEvent] = []
    @State private var levelFilter: WatchLevelFilter = .all

    var body: some View {
        List {
            Section(NSLocalizedString("文件", comment: "")) {
                Text(runFile.fileName)
                    .etFont(.caption2)
                    .lineLimit(2)
                Text("开发 \(runFile.developerEventCount) / 用户 \(runFile.userEventCount)")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("筛选", comment: "")) {
                Picker(NSLocalizedString("等级", comment: ""), selection: $levelFilter) {
                    ForEach(WatchLevelFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }

            Section(NSLocalizedString("记录", comment: "")) {
                if displayedEvents.isEmpty {
                    Text(NSLocalizedString("暂无匹配日志", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedEvents) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(entry.channel == .developer ? "开发" : "用户")
                                    .etFont(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(entry.channel == .developer ? .purple : .green)
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
                                .lineLimit(3)

                            if let payload = entry.payload, !payload.isEmpty {
                                Text(formatPayload(payload))
                                    .etFont(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(6)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("运行日志", comment: ""))
        .task(id: runFile.id) {
            let loaded = await logCenter.loadEvents(for: runFile)
            events = loaded.sorted { lhs, rhs in
                lhs.timestamp > rhs.timestamp
            }
        }
    }

    private var displayedEvents: [AppLogEvent] {
        switch levelFilter {
        case .all:
            return events
        case .debug:
            return events.filter { $0.level == .debug }
        case .info:
            return events.filter { $0.level == .info }
        case .warning:
            return events.filter { $0.level == .warning }
        case .error:
            return events.filter { $0.level == .error }
        }
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
}

private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}
