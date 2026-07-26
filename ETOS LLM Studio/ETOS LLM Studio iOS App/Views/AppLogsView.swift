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
import ETOSCore
#if canImport(UIKit)
import UIKit
#endif

struct AppLogsView: View {
    @StateObject private var logCenter = AppLogCenter.shared
    @StateObject private var telemetryCenter = PerformanceTelemetryCenter.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var selectedContent: AppLogContent = .requests
    @State private var showClearAllConfirm = false
    @State private var showClearTelemetryConfirm = false

    var body: some View {
        List {
            Section {
                Picker(NSLocalizedString("日志内容", comment: "Log content"), selection: $selectedContent) {
                    ForEach(AppLogContent.allCases) { content in
                        Text(content.title).tag(content)
                    }
                }
                .pickerStyle(.segmented)
            }

            if selectedContent == .requests {
                requestLogSections
            } else {
                telemetrySections
            }
        }
        .navigationTitle(NSLocalizedString("应用日志", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await logCenter.refreshLogFolders()
            await telemetryCenter.refreshVisibleRecords()
        }
        .refreshable {
            await logCenter.refreshLogFolders()
            await telemetryCenter.refreshVisibleRecords()
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
                Button(
                    selectedContent == .requests
                        ? NSLocalizedString("清空全部", comment: "")
                        : NSLocalizedString("清除待发送", comment: "Clear pending telemetry")
                ) {
                    if selectedContent == .requests {
                        showClearAllConfirm = true
                    } else {
                        showClearTelemetryConfirm = true
                    }
                }
                .disabled(
                    selectedContent == .requests
                        ? logCenter.logDayFolders.isEmpty
                        : telemetryCenter.pendingRecords.isEmpty
                )
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
            Text(NSLocalizedString("该操作不可撤销，会删除全部请求与响应日志，但不会删除性能遥测。", comment: ""))
        }
        .confirmationDialog(
            NSLocalizedString("确认清除待发送性能数据？", comment: "Confirm clearing telemetry"),
            isPresented: $showClearTelemetryConfirm,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("清除待发送性能数据", comment: "Clear pending telemetry"), role: .destructive) {
                Task {
                    await telemetryCenter.clearPendingData()
                }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("只会清除尚未发送的性能遥测，不会删除请求与响应日志。", comment: "Telemetry clear scope"))
        }
    }

    @ViewBuilder
    private var requestLogSections: some View {
        Section {
            Toggle(NSLocalizedString("启用 API 请求日志", comment: ""), isOn: $appConfig.requestLogEnabled)
            Toggle(NSLocalizedString("记录请求明文消息", comment: ""), isOn: $appConfig.requestLogPlainMessageEnabled)
                .disabled(!appConfig.requestLogEnabled)
        } footer: {
            Text(NSLocalizedString("关闭后不会保存请求与响应事务；开启后可选择是否记录聊天原文，图片、音频和文件的 Base64 始终隐藏。请求日志只保存在本机，不会自动上传。", comment: ""))
        }

        if logCenter.logDayFolders.isEmpty {
            ContentUnavailableView(NSLocalizedString("暂无请求日志", comment: ""),
                systemImage: "network",
                description: Text(NSLocalizedString("完成一次模型请求后，这里会按日期显示完整的请求与响应事务。", comment: ""))
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

    @ViewBuilder
    private var telemetrySections: some View {
        Section {
            LabeledContent(
                NSLocalizedString("性能改进", comment: "Performance improvement"),
                value: appConfig.performanceTelemetryEnabled
                    ? NSLocalizedString("已开启", comment: "")
                    : NSLocalizedString("已关闭", comment: "")
            )
            LabeledContent(
                NSLocalizedString("待发送", comment: "Pending telemetry"),
                value: String(
                    format: NSLocalizedString("%d 项 · %@", comment: "Telemetry count and size"),
                    telemetryCenter.pendingRecords.count,
                    formatByteCount(telemetryCenter.pendingBytes)
                )
            )
            if telemetryCenter.isUploading {
                Label(NSLocalizedString("正在发送上一启动的性能数据…", comment: "Uploading telemetry"), systemImage: "arrow.up.circle")
            } else if let error = telemetryCenter.lastUploadError {
                Label(error, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(NSLocalizedString("以下内容与自动发送的数据完全一致，不包含聊天内容、请求体、响应体、API Key、服务器地址或用户标识。原始调用栈需要对应构建的 dSYM 才能解析为代码位置。", comment: "Telemetry viewer disclosure"))
        }

        if telemetryCenter.pendingRecords.isEmpty {
            Section(NSLocalizedString("待发送", comment: "Pending telemetry")) {
                ContentUnavailableView(
                    NSLocalizedString("暂无待发送性能数据", comment: "No pending telemetry"),
                    systemImage: "waveform.path.ecg",
                    description: Text(NSLocalizedString("MetricKit 通常按系统安排提供聚合报告，并不保证每次启动都有新数据。", comment: "MetricKit delivery timing"))
                )
            }
        } else {
            Section(NSLocalizedString("待发送", comment: "Pending telemetry")) {
                ForEach(telemetryCenter.pendingRecords) { record in
                    NavigationLink {
                        TelemetryLogDetailView(record: record)
                    } label: {
                        TelemetryLogRow(record: record)
                    }
                }
            }
        }

        if !telemetryCenter.sentThisLaunchRecords.isEmpty {
            Section(NSLocalizedString("本次启动已发送", comment: "Telemetry sent this launch")) {
                ForEach(telemetryCenter.sentThisLaunchRecords) { record in
                    NavigationLink {
                        TelemetryLogDetailView(record: record)
                    } label: {
                        TelemetryLogRow(record: record)
                    }
                }
            }
        }
    }
}

private enum AppLogContent: String, CaseIterable, Identifiable {
    case requests
    case telemetry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .requests:
            return NSLocalizedString("请求与响应", comment: "Request and response logs")
        case .telemetry:
            return NSLocalizedString("性能遥测", comment: "Performance telemetry")
        }
    }
}

private struct TelemetryLogRow: View {
    let record: TelemetryLogRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(kindTitle, systemImage: kindIcon)
                    .etFont(.subheadline)
                Spacer()
                Text(deliveryTitle)
                    .etFont(.caption)
                    .foregroundStyle(deliveryColor)
            }
            Text(
                String(
                    format: NSLocalizedString("版本 %@ (%@) · %@", comment: "Telemetry version and capture time"),
                    record.envelope.app.version,
                    record.envelope.app.build,
                    formatTime(record.envelope.capturedAt)
                )
            )
            .etFont(.caption)
            .foregroundStyle(.secondary)
            Text(
                String(
                    format: NSLocalizedString("%@ · %@", comment: "Telemetry device and file size"),
                    record.envelope.platform.deviceClass,
                    formatByteCount(record.fileSizeBytes)
                )
            )
            .etFont(.caption2.monospaced())
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var kindTitle: String {
        record.envelope.kind == .metric
            ? NSLocalizedString("系统性能指标", comment: "Metric payload")
            : NSLocalizedString("性能诊断调用栈", comment: "Diagnostic payload")
    }

    private var kindIcon: String {
        record.envelope.kind == .metric ? "gauge.with.dots.needle.50percent" : "waveform.path.ecg.rectangle"
    }

    private var deliveryTitle: String {
        switch record.deliveryState {
        case .pending:
            return NSLocalizedString("待发送", comment: "Pending telemetry")
        case .sentThisLaunch:
            return NSLocalizedString("已发送", comment: "Sent telemetry")
        case .tooLarge:
            return NSLocalizedString("文件过大", comment: "Telemetry file too large")
        }
    }

    private var deliveryColor: Color {
        switch record.deliveryState {
        case .pending:
            return .orange
        case .sentThisLaunch:
            return .green
        case .tooLarge:
            return .red
        }
    }
}

private struct TelemetryLogDetailView: View {
    let record: TelemetryLogRecord
    @State private var channel: AppLogChannel = .user

    var body: some View {
        List {
            Section {
                Picker(NSLocalizedString("信息格式", comment: "Log presentation format"), selection: $channel) {
                    Text(NSLocalizedString("用户", comment: "")).tag(AppLogChannel.user)
                    Text(NSLocalizedString("开发", comment: "")).tag(AppLogChannel.developer)
                }
                .pickerStyle(.segmented)
            }

            if channel == .user {
                userSummary
            } else {
                developerDetails
            }
        }
        .navigationTitle(
            record.envelope.kind == .metric
                ? NSLocalizedString("系统性能指标", comment: "Metric payload")
                : NSLocalizedString("性能诊断", comment: "Diagnostic payload")
        )
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var userSummary: some View {
        Section(NSLocalizedString("数据摘要", comment: "Telemetry summary")) {
            LabeledContent(NSLocalizedString("类型", comment: ""), value: record.envelope.kind.rawValue)
            LabeledContent(
                NSLocalizedString("状态", comment: ""),
                value: record.deliveryState == .sentThisLaunch
                    ? NSLocalizedString("本次启动已发送", comment: "Telemetry sent this launch")
                    : NSLocalizedString("待发送", comment: "Pending telemetry")
            )
            LabeledContent(
                NSLocalizedString("版本", comment: ""),
                value: "\(record.envelope.app.version) (\(record.envelope.app.build))"
            )
            LabeledContent(
                NSLocalizedString("系统与设备", comment: "System and device"),
                value: "\(record.envelope.platform.deviceClass) · iOS \(record.envelope.platform.osVersion)"
            )
            LabeledContent(NSLocalizedString("统计时间范围", comment: "Telemetry period"), value: record.periodDescription)
            LabeledContent(NSLocalizedString("文件大小", comment: ""), value: formatByteCount(record.fileSizeBytes))
        }

        Section(NSLocalizedString("包含的数据类别", comment: "Telemetry categories")) {
            if record.payloadCategories.isEmpty {
                Text(NSLocalizedString("系统未列出指标类别", comment: "No MetricKit categories"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(record.payloadCategories, id: \.self) { category in
                    Text(category)
                        .etFont(.footnote.monospaced())
                }
            }
        }

        Section(NSLocalizedString("隐私", comment: "")) {
            Label(
                NSLocalizedString("不包含聊天内容、请求体、响应体、凭据或用户标识", comment: "Telemetry privacy summary"),
                systemImage: "checkmark.shield"
            )
            if record.envelope.kind == .diagnostic {
                Text(NSLocalizedString("调用栈中的地址和二进制 UUID 需要对应构建的 dSYM 才能还原为函数、文件和可能的行号。", comment: "dSYM explanation"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var developerDetails: some View {
        Section(NSLocalizedString("Envelope", comment: "Telemetry envelope")) {
            LabeledContent("schema_version", value: "\(record.envelope.schemaVersion)")
            LabeledContent("payload_id", value: record.envelope.payloadID)
                .textSelection(.enabled)
            LabeledContent("kind", value: record.envelope.kind.rawValue)
            LabeledContent("distribution", value: record.envelope.app.distribution.rawValue)
            if let relativePath = record.relativePath {
                LabeledContent("relative_path", value: relativePath)
                    .textSelection(.enabled)
            }
        }

        Section(NSLocalizedString("实际上传原文", comment: "Raw uploaded telemetry")) {
            ExpandableLogTextView(
                title: NSLocalizedString("实际上传原文", comment: "Raw uploaded telemetry"),
                text: record.rawJSON
            )
        }

        Section(NSLocalizedString("符号化说明", comment: "Symbolication explanation")) {
            Text(NSLocalizedString("客户端不会嵌入或下载 dSYM。请在 Mac 上按 Binary UUID 匹配对应的 Xcode Cloud .xcarchive；Release 优化可能使行号近似，函数和调用链通常更可靠。", comment: "Telemetry symbolication details"))
                .foregroundStyle(.secondary)
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
                    Text(String(format: NSLocalizedString("%@ · %d 个日志文件", comment: ""), dayFolder.day, dayFolder.runs.count))
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
    @State private var channel: AppLogChannel = .user

    var body: some View {
        List {
            Section {
                Picker(NSLocalizedString("信息格式", comment: "Log presentation format"), selection: $channel) {
                    Text(NSLocalizedString("用户", comment: "")).tag(AppLogChannel.user)
                    Text(NSLocalizedString("开发", comment: "")).tag(AppLogChannel.developer)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(
                    channel == .user
                        ? NSLocalizedString("用户格式显示请求体与最终响应信息；未开启明文记录时，流式响应只保留摘要。", comment: "")
                        : NSLocalizedString("开发格式额外显示耗时、状态码、用量与事务标识等诊断字段。", comment: "")
                )
            }

            Section(NSLocalizedString("日志文件信息", comment: "")) {
                LabeledContent(NSLocalizedString("日期文件夹", comment: ""), value: runFile.day)
                LabeledContent(NSLocalizedString("日志文件名", comment: ""), value: runFile.fileName)
                LabeledContent(NSLocalizedString("记录数", comment: ""), value: "\(runFile.totalEventCount)")
                LabeledContent(NSLocalizedString("可用格式", comment: ""), value: String(format: NSLocalizedString("开发 %d / 用户 %d", comment: ""), runFile.developerEventCount, runFile.userEventCount))
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
                        NavigationLink {
                            AppLogEventDetailView(entry: entry)
                        } label: {
                            AppLogDetailRow(entry: entry)
                        }
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
        return AppLogFilterEngine.filter(
            events.compactMap { $0.presented(in: channel) },
            with: filter
        )
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
                Text(String(format: NSLocalizedString("%d 个日志文件 · %d 条记录", comment: ""), dayFolder.runs.count, dayFolder.totalEventCount))
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

            Text(String(format: NSLocalizedString("共 %d 条 · 开发格式 %d / 用户格式 %d", comment: ""), runFile.totalEventCount, runFile.developerEventCount, runFile.userEventCount))
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
                Text(entry.channel == .developer ? NSLocalizedString("开发", comment: "") : NSLocalizedString("用户", comment: ""))
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

            Text(String(format: NSLocalizedString("事件ID：%@", comment: ""), entry.id.uuidString))
                .etFont(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            if let payload = entry.payload, !payload.isEmpty {
                Label(NSLocalizedString("详情", comment: ""), systemImage: "doc.text.magnifyingglass")
                    .etFont(.caption)
                    .foregroundStyle(.blue)
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

private struct AppLogEventDetailView: View {
    let entry: AppLogEvent

    var body: some View {
        List {
            Section(NSLocalizedString("基础信息", comment: "")) {
                LabeledContent(NSLocalizedString("等级", comment: ""), value: entry.level.displayName)
                LabeledContent(NSLocalizedString("分类（category）", comment: ""), value: entry.category)
                LabeledContent(NSLocalizedString("创建时间", comment: ""), value: formatTime(entry.timestamp))
                Text("\(entry.channel == .developer ? NSLocalizedString("开发", comment: "") : NSLocalizedString("用户", comment: "")) · \(entry.action)\n\(entry.id.uuidString)")
                    .etFont(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section(NSLocalizedString("日志记录", comment: "")) {
                Text(entry.message)
                    .textSelection(.enabled)
            }

            if let payload = entry.payload, !payload.isEmpty {
                Section(NSLocalizedString("payload", comment: "")) {
                    ForEach(payload.sorted { $0.key < $1.key }, id: \.key) { item in
                        NavigationLink {
                            AppLogPayloadValueDetailView(key: item.key, value: item.value)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.key)
                                    .etFont(.subheadline)
                                Text(payloadValueSummary(item.value))
                                    .etFont(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section(NSLocalizedString("详情", comment: "")) {
                    ExpandableLogTextView(
                        title: NSLocalizedString("详情", comment: ""),
                        text: formatLogPayload(payload)
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString("详情", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("复制", comment: "")) {
                    UIPasteboard.general.string = fullLogText
                }
            }
        }
    }

    private var fullLogText: String {
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
}

private struct AppLogPayloadValueDetailView: View {
    let key: String
    let value: String

    var body: some View {
        List {
            Section(key) {
                ExpandableLogTextView(
                    title: key,
                    text: prettyPayloadValue(value)
                )
            }
        }
        .navigationTitle(key)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("复制", comment: "")) {
                    UIPasteboard.general.string = prettyPayloadValue(value)
                }
            }
        }
    }
}

private struct ExpandableLogTextView: View {
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
        VStack(alignment: .leading, spacing: 8) {
            Text(displayedText)
                .etFont(.footnote.monospaced())
                .textSelection(.enabled)

            if needsExpansion {
                Text(String(format: NSLocalizedString("已显示前 %d 个字符，共 %d 个字符。", comment: ""), Self.previewLimit, textCharacterCount))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    AppLogPagedTextView(title: title, text: text)
                } label: {
                    Text(NSLocalizedString("显示完整内容", comment: ""))
                }
            }
        }
    }
}

private struct AppLogPagedTextView: View {
    let title: String
    let pages: [AppLogTextPage]
    let textCharacterCount: Int

    @State private var selectedPageIndex = 0

    private let paginationButtonColor = Color(red: 0.33, green: 0.47, blue: 0.65)

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
        List {
            Section {
                Text(currentPage.content)
                    .etFont(.footnote.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text(String(format: NSLocalizedString("第 %d / %d 页", comment: ""), currentPage.index + 1, currentPage.totalCount))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if hasMultiplePages {
                paginationBar
            }
        }
    }

    private var paginationBar: some View {
        HStack(spacing: 12) {
            Button {
                goToPreviousPage()
            } label: {
                Text("<")
                    .etFont(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(
                        Circle().fill(Color(uiColor: .systemBackground))
                    )
            }
            .foregroundStyle(paginationButtonColor)
            .disabled(!canGoToPreviousPage)
            .accessibilityLabel(NSLocalizedString("上一页", comment: ""))

            TextField("", text: .constant(paginationSummaryText))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .disabled(true)
                .allowsHitTesting(false)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color.clear)

            Button {
                goToNextPage()
            } label: {
                Text(">")
                    .etFont(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(
                        Circle().fill(Color(uiColor: .systemBackground))
                    )
            }
            .foregroundStyle(paginationButtonColor)
            .disabled(!canGoToNextPage)
            .accessibilityLabel(NSLocalizedString("下一页", comment: ""))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
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
    formatter.locale = .autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter.string(from: date)
}

private func formatByteCount(_ value: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useBytes]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: value)
}

private func formatLogPayload(_ payload: [String: String]) -> String {
    let sorted = payload.sorted { $0.key < $1.key }
    return sorted.map { "\($0.key):\n\(prettyPayloadValue($0.value))" }.joined(separator: "\n\n")
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
