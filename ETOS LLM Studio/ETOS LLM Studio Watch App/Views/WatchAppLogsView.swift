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
import ETOSCore

struct WatchAppLogsView: View {
    @StateObject private var logCenter = AppLogCenter.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var showClearAllConfirm = false

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("启用 API 请求日志", comment: ""), isOn: $appConfig.requestLogEnabled)
                    .buttonStyle(.plain)
                Toggle(NSLocalizedString("记录请求明文消息", comment: ""), isOn: $appConfig.requestLogPlainMessageEnabled)
                    .buttonStyle(.plain)
                    .disabled(!appConfig.requestLogEnabled)
                Text(NSLocalizedString("关闭后不会保存聊天请求日志或请求体快照；开启后可选择是否记录明文消息，图片、音频和文件的 Base64 仍会隐藏。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

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
                            Text(String(format: NSLocalizedString("%d 个文件 · %d 条", comment: ""), dayFolder.runs.count, dayFolder.totalEventCount))
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
                            Text(String(format: NSLocalizedString("%@ · %d 条", comment: ""), formatTime(runFile.createdAt), runFile.totalEventCount))
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
                Text(String(format: NSLocalizedString("开发 %d / 用户 %d", comment: ""), runFile.developerEventCount, runFile.userEventCount))
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
                        NavigationLink {
                            WatchAppLogEventDetailView(entry: entry)
                        } label: {
                            WatchAppLogEventRow(entry: entry)
                        }
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

}

private struct WatchAppLogEventRow: View {
    let entry: AppLogEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.channel == .developer ? NSLocalizedString("开发", comment: "") : NSLocalizedString("用户", comment: ""))
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

            if entry.payload?.isEmpty == false {
                Label(NSLocalizedString("详情", comment: ""), systemImage: "doc.text.magnifyingglass")
                    .etFont(.system(size: 9))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct WatchAppLogEventDetailView: View {
    let entry: AppLogEvent

    var body: some View {
        List {
            Section(NSLocalizedString("基础信息", comment: "")) {
                Text("\(entry.channel == .developer ? NSLocalizedString("开发", comment: "") : NSLocalizedString("用户", comment: "")) · \(entry.level.displayName)")
                    .etFont(.caption)
                    .foregroundStyle(levelColor(entry.level))
                Text("\(entry.category) · \(entry.action)")
                    .etFont(.caption2)
                Text(formatTime(entry.timestamp))
                    .etFont(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("记录", comment: "")) {
                Text(entry.message)
                    .etFont(.caption2)
            }

            if let payload = entry.payload, !payload.isEmpty {
                Section(NSLocalizedString("payload", comment: "")) {
                    ForEach(payload.sorted { $0.key < $1.key }, id: \.key) { item in
                        NavigationLink {
                            WatchAppLogPayloadValueDetailView(key: item.key, value: item.value)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.key)
                                    .etFont(.caption2)
                                Text(payloadValueSummary(item.value))
                                    .etFont(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("详情", comment: ""))
    }
}

private struct WatchAppLogPayloadValueDetailView: View {
    let key: String
    let value: String

    var body: some View {
        List {
            Section(key) {
                WatchExpandableLogTextView(
                    title: key,
                    text: prettyPayloadValue(value)
                )
            }
        }
        .navigationTitle(key)
    }
}

private struct WatchExpandableLogTextView: View {
    let title: String
    let text: String
    let displayedText: String
    let textCharacterCount: Int
    let needsExpansion: Bool

    private static let previewLimit = AppLogTextPaginator.defaultPageSize

    init(title: String, text: String) {
        self.title = title
        self.text = text
        let characterCount = text.count
        let expands = characterCount > Self.previewLimit
        self.textCharacterCount = characterCount
        self.needsExpansion = expands
        self.displayedText = expands ? String(text.prefix(Self.previewLimit)) : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(displayedText)
                .etFont(.system(size: 9, design: .monospaced))

            if needsExpansion {
                Text(String(format: NSLocalizedString("已显示前 %d 个字符，共 %d 个字符。", comment: ""), Self.previewLimit, textCharacterCount))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    WatchAppLogPagedTextView(title: title, text: text)
                } label: {
                    Text(NSLocalizedString("显示完整内容", comment: ""))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct WatchAppLogPagedTextView: View {
    let title: String
    let pages: [AppLogTextPage]
    let textCharacterCount: Int

    @State private var selectedPageIndex = 0

    init(title: String, text: String) {
        self.title = title
        self.pages = AppLogTextPaginator.paginate(text)
        self.textCharacterCount = text.count
    }

    private var currentPage: AppLogTextPage {
        let clampedIndex = min(max(selectedPageIndex, 0), pages.count - 1)
        return pages[clampedIndex]
    }

    private var hasMultiplePages: Bool {
        pages.count > 1
    }

    private var canGoToPreviousPage: Bool {
        selectedPageIndex > 0
    }

    private var canGoToNextPage: Bool {
        selectedPageIndex + 1 < pages.count
    }

    private var paginationSummaryText: String {
        String(format: NSLocalizedString("当前显示%d-%d条结果(总共%d)", comment: ""), currentPage.startCharacterNumber, currentPage.endCharacterNumber, textCharacterCount)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: NSLocalizedString("第 %d / %d 页", comment: ""), currentPage.index + 1, currentPage.totalCount))
                        .etFont(.caption.weight(.semibold))
                    Text(paginationSummaryText)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )

                Text(currentPage.content)
                    .etFont(.system(size: 9, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .navigationTitle(title)
        .toolbar {
            if hasMultiplePages {
                ToolbarItem(placement: .bottomBar) {
                    paginationBottomBar
                }
            }
        }
    }

    private var paginationBottomBar: some View {
        HStack(spacing: 8) {
            Button {
                goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoToPreviousPage)
            .accessibilityLabel(NSLocalizedString("上一页", comment: ""))

            Spacer(minLength: 4)

            MarqueeText(
                content: paginationSummaryText,
                uiFont: .preferredFont(forTextStyle: .footnote),
                speed: 28,
                delay: 0.8,
                spacing: 24
            )
            .multilineTextAlignment(.center)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 4)

            Button {
                goToNextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoToNextPage)
            .accessibilityLabel(NSLocalizedString("下一页", comment: ""))
        }
    }

    private func goToPreviousPage() {
        guard canGoToPreviousPage else { return }
        selectedPageIndex -= 1
    }

    private func goToNextPage() {
        guard canGoToNextPage else { return }
        selectedPageIndex += 1
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
            return NSLocalizedString("全部", comment: "")
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
    formatter.locale = .autoupdatingCurrent
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

private func payloadValueSummary(_ value: String) -> String {
    let pretty = prettyPayloadValue(value)
    return pretty
        .split(separator: "\n", omittingEmptySubsequences: true)
        .prefix(3)
        .joined(separator: "\n")
}

private func prettyPayloadValue(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8),
          let jsonObject = try? JSONSerialization.jsonObject(with: data),
          JSONSerialization.isValidJSONObject(jsonObject),
          let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
          let pretty = String(data: prettyData, encoding: .utf8) else {
        return value
    }
    return pretty
}
