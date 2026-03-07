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

    var body: some View {
        List {
            Section {
                Picker("日志类型", selection: $selectedChannel) {
                    Text("用户").tag(AppLogChannel.user)
                    Text("开发者").tag(AppLogChannel.developer)
                }
                .pickerStyle(.segmented)
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
        Array(logCenter.recentLogs(for: selectedChannel, limit: 300).reversed())
    }

    private func copyLogsToClipboard() {
        let content = displayedLogs
            .map { entry in
                "[\(formatTime(entry.timestamp))] [\(entry.level.displayName)] [\(entry.category)] [\(entry.action)] \(entry.message)"
            }
            .joined(separator: "\n")

        #if canImport(UIKit)
        UIPasteboard.general.string = content
        #endif
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
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
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatPayload(_ payload: [String: String]) -> String {
        let sorted = payload.sorted { $0.key < $1.key }
        return sorted.map { "\($0.key)=\($0.value)" }.joined(separator: " · ")
    }
}
