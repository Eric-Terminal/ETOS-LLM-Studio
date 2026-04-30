// ============================================================================
// AppLogsView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 功能特性:
// - 以“日期文件夹 -> 运行日志文件”的层级查看日志
// - 用户/开发日志统一展示
// - 支持按日志文件查看、筛选、复制详细内容
// ============================================================================

import SwiftUI
import Shared
#if canImport(UIKit)
import UIKit
#endif

struct AppLogsView: View {
    @StateObject private var logCenter = AppLogCenter.shared
    @State private var showClearAllConfirm = false

    var body: some View {
        List {
            if logCenter.logDayFolders.isEmpty {
                ContentUnavailableView(NSLocalizedString("暂无日志目录", comment: ""),
                    systemImage: "folder",
                    description: Text(NSLocalizedString("应用运行并产生日志后，这里会按日期生成文件夹。", comment: ""))
                )
            } else {
                Section(NSLocalizedString("按日期查看", comment: "")) {
                    ForEach(logCenter.logDayFolders) { dayFolder in
                        NavigationLink {
                            AppLogDayRunsView(logCenter: logCenter, dayFolderID: dayFolder.id)
                        } label: {
                            AppLogDayFolderRow(dayFolder: dayFolder)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                                logCenter.deleteDayFolder(dayFolder)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("应用日志", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await logCenter.refreshLogFolders()
        }
        .refreshable {
            await logCenter.refreshLogFolders()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(NSLocalizedString("刷新", comment: "")) {
                    Task {
                        await logCenter.refreshLogFolders()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("清空全部", comment: "")) {
                    showClearAllConfirm = true
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
            Text(NSLocalizedString("该操作不可撤销，会删除全部日期文件夹和运行日志文件。", comment: ""))
        }
    }
}

private struct AppLogDayRunsView: View {
    @ObservedObject var logCenter: AppLogCenter
    let dayFolderID: String

    private var dayFolder: AppLogDayFolder? {
        logCenter.logDayFolders.first(where: { $0.id == dayFolderID })
    }

    var body: some View {
        List {
            if let dayFolder {
                Section {
                    ForEach(dayFolder.runs) { runFile in
                        NavigationLink {
                            AppLogRunDetailView(logCenter: logCenter, runFile: runFile)
                        } label: {
                            AppLogRunFileRow(runFile: runFile)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                                logCenter.deleteRunFile(runFile)
                            }
                        }
                    }
                } header: {
                    Text("\(dayFolder.day) · \(dayFolder.runs.count) 个日志文件")
                } footer: {
                    Text(NSLocalizedString("每次应用运行都会写入一个新的日志文件。", comment: ""))
                }
            } else {
                ContentUnavailableView(NSLocalizedString("日志目录已更新", comment: ""),
                    systemImage: "arrow.clockwise",
                    description: Text(NSLocalizedString("请返回上级列表重新进入。", comment: ""))
                )
            }
        }
        .navigationTitle(dayFolderID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("刷新", comment: "")) {
                    Task {
                        await logCenter.refreshLogFolders()
                    }
                }
            }
        }
    }
}

private struct AppLogRunDetailView: View {
    @ObservedObject var logCenter: AppLogCenter
    let runFile: AppLogRunFile

    @State private var events: [AppLogEvent] = []
    @State private var keywordFilter = ""
    @State private var categoryFilter = ""
    @State private var levelFilter: LevelFilter = .all
    @State private var configChangesOnly = false

    var body: some View {
        List {
            Section(NSLocalizedString("日志文件信息", comment: "")) {
                LabeledContent(NSLocalizedString("日期文件夹", comment: ""), value: runFile.day)
                LabeledContent(NSLocalizedString("日志文件名", comment: ""), value: runFile.fileName)
                LabeledContent(NSLocalizedString("记录数", comment: ""), value: "\(runFile.totalEventCount)")
                LabeledContent(NSLocalizedString("来源分布", comment: ""), value: "开发 \(runFile.developerEventCount) / 用户 \(runFile.userEventCount)")
                LabeledContent(NSLocalizedString("文件大小", comment: ""), value: formatByteCount(runFile.fileSizeBytes))
                LabeledContent(NSLocalizedString("创建时间", comment: ""), value: formatTime(runFile.createdAt))
                LabeledContent(NSLocalizedString("最后更新", comment: ""), value: formatTime(runFile.updatedAt))
            }

            Section(NSLocalizedString("筛选", comment: "")) {
                TextField(NSLocalizedString("关键词（消息 / 动作 / payload）", comment: ""), text: $keywordFilter)
                    .textInputAutocapitalization(.never)
                TextField(NSLocalizedString("分类（category）", comment: ""), text: $categoryFilter)
                    .textInputAutocapitalization(.never)

                Picker(NSLocalizedString("等级", comment: ""), selection: $levelFilter) {
                    ForEach(LevelFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)

                Toggle(NSLocalizedString("仅看配置变更", comment: ""), isOn: $configChangesOnly)

                if hasActiveFilters {
                    Button(NSLocalizedString("重置筛选", comment: "")) {
                        keywordFilter = ""
                        categoryFilter = ""
                        levelFilter = .all
                        configChangesOnly = false
                    }
                }
            }

            Section(NSLocalizedString("日志记录", comment: "")) {
                if displayedEvents.isEmpty {
                    ContentUnavailableView(NSLocalizedString("没有匹配的日志", comment: ""),
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(NSLocalizedString("调整筛选条件或等待新日志写入。", comment: ""))
                    )
                } else {
                    ForEach(displayedEvents) { entry in
                        AppLogDetailRow(entry: entry)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("运行日志", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: runFile.id) {
            await reload()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(NSLocalizedString("刷新", comment: "")) {
                    Task {
                        await reload()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("复制", comment: "")) {
                    copyLogsToClipboard()
                }
                .disabled(displayedEvents.isEmpty)
            }
        }
    }

    private var displayedEvents: [AppLogEvent] {
        let filter = AppLogFilter(
            level: levelFilter.level,
            keyword: keywordFilter,
            categoryKeyword: categoryFilter,
            configChangesOnly: configChangesOnly
        )
        return AppLogFilterEngine.filter(events, with: filter)
    }

    private var hasActiveFilters: Bool {
        !keywordFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !categoryFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        levelFilter != .all ||
        configChangesOnly
    }

    private func reload() async {
        let loaded = await logCenter.loadEvents(for: runFile)
        events = loaded.sorted { lhs, rhs in
            lhs.timestamp > rhs.timestamp
        }
    }

    private func copyLogsToClipboard() {
        let content = displayedEvents
            .map { entry in
                var lines: [String] = [
                    "[\(formatTime(entry.timestamp))] [\(entry.channel.displayName)] [\(entry.level.displayName)] [\(entry.category)] [\(entry.action)]",
                    "message: \(entry.message)",
                    "eventID: \(entry.id.uuidString)"
                ]
                if let payload = entry.payload, !payload.isEmpty {
                    lines.append("payload:")
                    lines.append(formatLogPayload(payload))
                }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n\n")

        #if canImport(UIKit)
        UIPasteboard.general.string = content
        #endif
    }

    private func formatByteCount(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}

private struct AppLogDayFolderRow: View {
    let dayFolder: AppLogDayFolder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(dayFolder.day)
                    .etFont(.headline)
                Text("\(dayFolder.runs.count) 个日志文件 · \(dayFolder.totalEventCount) 条记录")
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct AppLogRunFileRow: View {
    let runFile: AppLogRunFile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.blue)
                Text(runFile.fileName)
                    .etFont(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(formatTime(runFile.createdAt))
                    .etFont(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text("共 \(runFile.totalEventCount) 条 · 开发 \(runFile.developerEventCount) / 用户 \(runFile.userEventCount)")
                .etFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct AppLogDetailRow: View {
    let entry: AppLogEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.channel == .developer ? "开发" : "用户")
                    .etFont(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(channelColor.opacity(0.15))
                    .foregroundStyle(channelColor)
                    .clipShape(Capsule())

                Text(entry.level.displayName)
                    .etFont(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(levelColor.opacity(0.15))
                    .foregroundStyle(levelColor)
                    .clipShape(Capsule())

                Spacer(minLength: 8)

                Text(formatTime(entry.timestamp))
                    .etFont(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text("\(entry.category) · \(entry.action)")
                .etFont(.subheadline)

            Text(entry.message)
                .etFont(.caption)
                .foregroundStyle(.secondary)

            Text("事件ID：\(entry.id.uuidString)")
                .etFont(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            if let payload = entry.payload, !payload.isEmpty {
                Text(formatLogPayload(payload))
                    .etFont(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
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

    private var channelColor: Color {
        switch entry.channel {
        case .developer:
            return .purple
        case .user:
            return .green
        }
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

private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter.string(from: date)
}

private func formatLogPayload(_ payload: [String: String]) -> String {
    let sorted = payload.sorted { $0.key < $1.key }
    return sorted.map { "\($0.key):\n\($0.value)" }.joined(separator: "\n\n")
}
