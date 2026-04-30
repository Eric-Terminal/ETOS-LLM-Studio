// ============================================================================
// ThirdPartyImportWatchHintView.swift
// ============================================================================
// 导入数据页面 (watchOS)
// - 支持通过 URL 下载导出文件并在手表端解析导入
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct ThirdPartyImportWatchHintView: View {
    @State private var selectedSource: ThirdPartyImportSource = .etosBackup
    @State private var importURLText: String = ""
    @State private var isPreparing: Bool = false
    @State private var isImporting: Bool = false
    @State private var selectedFileName: String = ""
    @State private var preparedResult: ThirdPartyImportPreparedResult?
    @State private var conflictPreview: ConflictPreview = .empty
    @State private var includeProviders: Bool = true
    @State private var includeSessions: Bool = true
    @State private var importReport: ThirdPartyImportReport?
    @State private var importError: String?

    var body: some View {
        List {
            Section(NSLocalizedString("导入来源", comment: "")) {
                Picker(NSLocalizedString("数据来源", comment: ""), selection: $selectedSource) {
                    ForEach(ThirdPartyImportSource.allCases, id: \.self) { source in
                        Text(source.displayName)
                            .tag(source)
                    }
                }
                .pickerStyle(.navigationLink)

                Text(sourceHint(for: selectedSource))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("导入操作", comment: "")) {
                TextField(NSLocalizedString("导入文件链接", comment: ""), text: $importURLText.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    startURLPreparation()
                } label: {
                    Label(NSLocalizedString("下载并解析", comment: ""), systemImage: "arrow.down.doc")
                }
                .disabled(isBusy || importURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !selectedFileName.isEmpty {
                    row(title: "最近解析", value: selectedFileName)
                }

                if isPreparing {
                    progressRow(text: "正在下载并解析...")
                }

                if isImporting {
                    progressRow(text: "正在导入并合并数据...")
                }

                Text(NSLocalizedString("支持 http/https 的 JSON 链接。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let preparedResult {
                Section(NSLocalizedString("解析预览", comment: "")) {
                    if preparedResult.source == .etosBackup {
                        row(title: "导出同步项", value: syncOptionSummary(preparedResult.package.options))
                    }
                    row(title: "识别到提供商", value: "\(preparedResult.parsedProvidersCount)")
                    row(title: "识别到会话", value: "\(preparedResult.parsedSessionsCount)")
                    if preparedResult.source != .etosBackup {
                        row(title: "可能冲突提供商", value: "\(conflictPreview.providerConflicts)")
                        row(title: "可能冲突会话", value: "\(conflictPreview.sessionConflicts)")
                        row(title: "预计新增提供商", value: "\(conflictPreview.providerAdds)")
                        row(title: "预计新增会话", value: "\(conflictPreview.sessionAdds)")
                    }
                }

                Section(NSLocalizedString("导入范围", comment: "")) {
                    if preparedResult.source == .etosBackup {
                        Text(NSLocalizedString("ETOS 数据包会按导出时勾选的同步项全量导入。", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        if preparedResult.parsedProvidersCount > 0 {
                            Toggle(NSLocalizedString("导入提供商配置", comment: ""), isOn: $includeProviders)
                        }

                        if preparedResult.parsedSessionsCount > 0 {
                            Toggle(NSLocalizedString("导入会话记录", comment: ""), isOn: $includeSessions)
                        }
                    }

                    Button {
                        startImport()
                    } label: {
                        Label(NSLocalizedString("确认导入", comment: ""), systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(isBusy || !canStartImport)
                }

                if !preparedResult.warnings.isEmpty {
                    Section(NSLocalizedString("解析提示", comment: "")) {
                        ForEach(preparedResult.warnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let importReport {
                Section(NSLocalizedString("最近导入结果", comment: "")) {
                    row(title: "本次解析提供商", value: "\(importReport.parsedProvidersCount)")
                    row(title: "本次解析会话", value: "\(importReport.parsedSessionsCount)")
                    row(title: "新增提供商", value: "\(importReport.summary.importedProviders)")
                    row(title: "跳过提供商", value: "\(importReport.summary.skippedProviders)")
                    row(title: "新增会话", value: "\(importReport.summary.importedSessions)")
                    row(title: "跳过会话", value: "\(importReport.summary.skippedSessions)")
                }

                if !importReport.warnings.isEmpty {
                    Section(NSLocalizedString("导入提示", comment: "")) {
                        ForEach(importReport.warnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let importError, !importError.isEmpty {
                Section(NSLocalizedString("导入错误", comment: "")) {
                    Text(importError)
                        .etFont(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(NSLocalizedString("导入数据", comment: ""))
        .onChange(of: selectedSource) { _, _ in
            resetPreparedState()
        }
    }

    private var isBusy: Bool {
        isPreparing || isImporting
    }

    private var canStartImport: Bool {
        guard let preparedResult else { return false }
        if preparedResult.source == .etosBackup {
            return !preparedResult.package.options.isEmpty
        }
        let hasProviderSelection = includeProviders && preparedResult.parsedProvidersCount > 0
        let hasSessionSelection = includeSessions && preparedResult.parsedSessionsCount > 0
        return hasProviderSelection || hasSessionSelection
    }

    private func sourceHint(for source: ThirdPartyImportSource) -> String {
        switch source {
        case .etosBackup:
            return NSLocalizedString("支持导入 ETOS 导出的 JSON 数据包（含“同步与备份”导出）。", comment: "")
        case .cherryStudio:
            return NSLocalizedString("支持 Cherry Studio 的 .json；若是 .zip / .bak，请先解压后再导入。", comment: "")
        case .rikkahub:
            return NSLocalizedString("支持 RikkaHub 的 settings.json（当前先导入提供商配置）。", comment: "")
        case .kelivo:
            return NSLocalizedString("支持 Kelivo 的 settings.json + chats.json（建议使用包含两者的 JSON 目录导出内容）。", comment: "")
        case .chatgpt:
            return NSLocalizedString("支持 ChatGPT 官方 conversations.json。", comment: "")
        }
    }

    private func startURLPreparation() {
        let trimmed = importURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            importError = NSLocalizedString("链接不能为空。", comment: "")
            return
        }
        guard let url = URL(string: trimmed) else {
            importError = NSLocalizedString("链接格式无效，请输入完整 URL。", comment: "")
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            importError = NSLocalizedString("仅支持 http/https 链接。", comment: "")
            return
        }

        isPreparing = true
        importError = nil
        importReport = nil
        preparedResult = nil
        conflictPreview = .empty

        let source = selectedSource
        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 45
                let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    await MainActor.run {
                        importError = String(format: NSLocalizedString("下载失败：HTTP %d", comment: ""), httpResponse.statusCode)
                        isPreparing = false
                    }
                    return
                }

                let fileName = suggestedRemoteImportFileName(from: url, response: response, data: data, source: source)
                let tempURL = makeTemporaryFileURL(fileName: fileName)
                try data.write(to: tempURL, options: [.atomic])
                defer {
                    try? FileManager.default.removeItem(at: tempURL)
                }

                let prepared = try ThirdPartyImportService.prepareImport(source: source, fileURL: tempURL)
                let preview = buildConflictPreview(for: prepared.package)

                await MainActor.run {
                    selectedFileName = fileName
                    preparedResult = prepared
                    includeProviders = prepared.package.options.contains(.providers)
                    includeSessions = prepared.package.options.contains(.sessions)
                    conflictPreview = preview
                    isPreparing = false
                }
            } catch {
                await MainActor.run {
                    importError = error.localizedDescription
                    isPreparing = false
                }
            }
        }
    }

    private func startImport() {
        guard let preparedResult else { return }

        if preparedResult.source == .etosBackup {
            guard !preparedResult.package.options.isEmpty else {
                importError = NSLocalizedString("导出包没有包含可导入的数据。", comment: "")
                return
            }

            isImporting = true
            importError = nil

            Task {
                let summary = await SyncEngine.apply(package: preparedResult.package)
                let report = ThirdPartyImportReport(
                    source: preparedResult.source,
                    parsedProvidersCount: preparedResult.parsedProvidersCount,
                    parsedSessionsCount: preparedResult.parsedSessionsCount,
                    summary: summary,
                    warnings: preparedResult.warnings
                )

                await MainActor.run {
                    importReport = report
                    isImporting = false
                }
            }
            return
        }

        var options: SyncOptions = []
        let providers: [Provider]
        let sessions: [SyncedSession]

        if includeProviders, preparedResult.parsedProvidersCount > 0 {
            options.insert(.providers)
            providers = preparedResult.package.providers
        } else {
            providers = []
        }

        if includeSessions, preparedResult.parsedSessionsCount > 0 {
            options.insert(.sessions)
            sessions = preparedResult.package.sessions
        } else {
            sessions = []
        }

        guard !options.isEmpty else {
            importError = NSLocalizedString("请至少选择一个导入项。", comment: "")
            return
        }

        isImporting = true
        importError = nil

        Task {
            let scopedPackage = SyncPackage(
                options: options,
                providers: providers,
                sessions: sessions
            )

            let summary = await SyncEngine.apply(package: scopedPackage)
            let report = ThirdPartyImportReport(
                source: preparedResult.source,
                parsedProvidersCount: providers.count,
                parsedSessionsCount: sessions.count,
                summary: summary,
                warnings: preparedResult.warnings
            )

            await MainActor.run {
                importReport = report
                isImporting = false
            }
        }
    }

    private func resetPreparedState() {
        selectedFileName = ""
        preparedResult = nil
        importReport = nil
        importError = nil
        conflictPreview = .empty
        includeProviders = true
        includeSessions = true
    }

    private func makeTemporaryFileURL(fileName: String) -> URL {
        let rawName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedName = rawName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        return FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(sanitizedName)")
    }

    private func suggestedRemoteImportFileName(
        from url: URL,
        response: URLResponse,
        data: Data,
        source: ThirdPartyImportSource
    ) -> String {
        var fileName = response.suggestedFilename?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if fileName.isEmpty {
            fileName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if fileName.isEmpty || fileName == "/" {
            fileName = "import-data"
        }

        if !(fileName as NSString).pathExtension.isEmpty {
            return fileName
        }

        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if contentType.contains("zip") {
                return "\(fileName).zip"
            }
            if contentType.contains("json") {
                return "\(fileName).json"
            }
        }

        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return "\(fileName).zip"
        }

        if source == .chatgpt || source == .etosBackup {
            return "\(fileName).json"
        }
        return "\(fileName).json"
    }

    private func buildConflictPreview(for package: SyncPackage) -> ConflictPreview {
        let providerConflicts = estimateProviderConflicts(incoming: package.providers)
        let providerAdds = max(0, package.providers.count - providerConflicts)

        let sessionConflicts = estimateSessionConflicts(incoming: package.sessions)
        let sessionAdds = max(0, package.sessions.count - sessionConflicts)

        return ConflictPreview(
            providerConflicts: providerConflicts,
            sessionConflicts: sessionConflicts,
            providerAdds: providerAdds,
            sessionAdds: sessionAdds
        )
    }

    private func estimateProviderConflicts(incoming: [Provider]) -> Int {
        guard !incoming.isEmpty else { return 0 }
        let locals = ConfigLoader.loadProviders()
        let localSignatures = Set(locals.map(providerSignature))
        return incoming.reduce(into: 0) { count, provider in
            if localSignatures.contains(providerSignature(provider)) {
                count += 1
            }
        }
    }

    private func estimateSessionConflicts(incoming: [SyncedSession]) -> Int {
        guard !incoming.isEmpty else { return 0 }

        let localSessions = Persistence.loadChatSessions().filter { !$0.isTemporary }
        let localSessionIDs = Set(localSessions.map(\.id))

        var localSignatures: Set<String> = []
        localSignatures.reserveCapacity(localSessions.count)
        for session in localSessions {
            let messages = Persistence.loadMessages(for: session.id)
            localSignatures.insert(sessionSignature(name: session.name, messages: messages))
        }

        return incoming.reduce(into: 0) { count, incomingSession in
            if localSessionIDs.contains(incomingSession.session.id) {
                count += 1
                return
            }
            let signature = sessionSignature(
                name: incomingSession.session.name,
                messages: incomingSession.messages
            )
            if localSignatures.contains(signature) {
                count += 1
            }
        }
    }

    private func providerSignature(_ provider: Provider) -> String {
        [
            provider.name.lowercased(),
            provider.baseURL.lowercased(),
            provider.apiFormat.lowercased(),
            provider.models.map(\.modelName).sorted().joined(separator: ",").lowercased()
        ].joined(separator: "|")
    }

    private func sessionSignature(name: String, messages: [ChatMessage]) -> String {
        let first = messages.first
        let last = messages.last
        let firstSnippet = String((first?.content ?? "").prefix(80)).lowercased()
        let lastSnippet = String((last?.content ?? "").prefix(80)).lowercased()

        return [
            name.lowercased(),
            "\(messages.count)",
            first?.role.rawValue ?? "",
            last?.role.rawValue ?? "",
            firstSnippet,
            lastSnippet
        ].joined(separator: "|")
    }

    @ViewBuilder
    private func progressRow(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(NSLocalizedString(text, comment: "导入进度文本"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(NSLocalizedString(title, comment: "导入信息行标题"))
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func syncOptionSummary(_ options: SyncOptions) -> String {
        var items: [String] = []
        if options.contains(.providers) { items.append(NSLocalizedString("提供商配置", comment: "")) }
        if options.contains(.sessions) { items.append(NSLocalizedString("会话记录", comment: "")) }
        if options.contains(.backgrounds) { items.append(NSLocalizedString("背景图片", comment: "")) }
        if options.contains(.memories) { items.append(NSLocalizedString("记忆", comment: "")) }
        if options.contains(.mcpServers) { items.append(NSLocalizedString("MCP 服务器", comment: "")) }
        if options.contains(.audioFiles) { items.append(NSLocalizedString("音频文件", comment: "")) }
        if options.contains(.imageFiles) { items.append(NSLocalizedString("图片文件", comment: "")) }
        if options.contains(.skills) { items.append("Agent Skills") }
        if options.contains(.shortcutTools) { items.append(NSLocalizedString("快捷指令工具", comment: "")) }
        if options.contains(.worldbooks) { items.append(NSLocalizedString("世界书", comment: "")) }
        if options.contains(.feedbackTickets) { items.append(NSLocalizedString("反馈工单", comment: "")) }
        if options.contains(.dailyPulse) { items.append(NSLocalizedString("每日脉冲", comment: "")) }
        if options.contains(.usageStats) { items.append(NSLocalizedString("用量统计", comment: "")) }
        if options.contains(.fontFiles) { items.append(NSLocalizedString("字体文件与规则", comment: "")) }
        if options.contains(.appStorage) { items.append(NSLocalizedString("软件设置", comment: "")) }
        return items.isEmpty ? NSLocalizedString("无", comment: "") : items.joined(separator: NSLocalizedString("、", comment: ""))
    }
}

private struct ConflictPreview {
    var providerConflicts: Int
    var sessionConflicts: Int
    var providerAdds: Int
    var sessionAdds: Int

    static let empty = ConflictPreview(
        providerConflicts: 0,
        sessionConflicts: 0,
        providerAdds: 0,
        sessionAdds: 0
    )
}
