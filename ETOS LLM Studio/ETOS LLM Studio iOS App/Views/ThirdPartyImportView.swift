// ============================================================================
// ThirdPartyImportView.swift
// ============================================================================
// 第三方导入页面 (iOS)
// - 提供来源选择 + 文件导入
// - 导入后展示解析与合并摘要
// ============================================================================

import SwiftUI
import UniformTypeIdentifiers
import Shared

struct ThirdPartyImportView: View {
    @State private var selectedSource: ThirdPartyImportSource = .cherryStudio
    @State private var isFileImporterPresented: Bool = false
    @State private var isImporting: Bool = false
    @State private var selectedFileName: String = ""
    @State private var importReport: ThirdPartyImportReport?
    @State private var importError: String?

    var body: some View {
        List {
            Section(NSLocalizedString("导入来源", comment: "Third-party import source section title")) {
                Picker(
                    NSLocalizedString("数据来源", comment: "Third-party data source picker title"),
                    selection: $selectedSource
                ) {
                    ForEach(ThirdPartyImportSource.allCases, id: \.self) { source in
                        Text(source.displayName)
                            .tag(source)
                    }
                }
                .pickerStyle(.navigationLink)

                Text(sourceHint(for: selectedSource))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("导入操作", comment: "Third-party import action section title")) {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label(
                        NSLocalizedString("选择文件并导入", comment: "Select file and import button"),
                        systemImage: "square.and.arrow.down.on.square"
                    )
                }
                .disabled(isImporting)

                if !selectedFileName.isEmpty {
                    row(
                        title: NSLocalizedString("最近选择", comment: "Last selected file row title"),
                        value: selectedFileName
                    )
                }

                if isImporting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(NSLocalizedString("正在导入并合并数据...", comment: "Importing progress text"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let importReport {
                Section(NSLocalizedString("最近导入结果", comment: "Latest import summary section title")) {
                    row(
                        title: NSLocalizedString("识别到提供商", comment: "Parsed providers row"),
                        value: "\(importReport.parsedProvidersCount)"
                    )
                    row(
                        title: NSLocalizedString("识别到会话", comment: "Parsed sessions row"),
                        value: "\(importReport.parsedSessionsCount)"
                    )
                    row(
                        title: NSLocalizedString("新增提供商", comment: "Imported providers row"),
                        value: "\(importReport.summary.importedProviders)"
                    )
                    row(
                        title: NSLocalizedString("跳过提供商", comment: "Skipped providers row"),
                        value: "\(importReport.summary.skippedProviders)"
                    )
                    row(
                        title: NSLocalizedString("新增会话", comment: "Imported sessions row"),
                        value: "\(importReport.summary.importedSessions)"
                    )
                    row(
                        title: NSLocalizedString("跳过会话", comment: "Skipped sessions row"),
                        value: "\(importReport.summary.skippedSessions)"
                    )
                }

                if !importReport.warnings.isEmpty {
                    Section(NSLocalizedString("导入提示", comment: "Import warnings section title")) {
                        ForEach(importReport.warnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let importError, !importError.isEmpty {
                Section(NSLocalizedString("导入错误", comment: "Import error section title")) {
                    Text(importError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(NSLocalizedString("第三方导入", comment: "Third-party import nav title"))
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }

    private var allowedContentTypes: [UTType] {
        var identifiers: Set<String> = []
        var types: [UTType] = []

        func append(_ type: UTType) {
            if identifiers.insert(type.identifier).inserted {
                types.append(type)
            }
        }

        append(.json)
        append(.data)
        append(.folder)

        if selectedSource != .chatgpt {
            if let zipType = UTType(filenameExtension: "zip") {
                append(zipType)
            }
            if let bakType = UTType(filenameExtension: "bak") {
                append(bakType)
            }
        }

        return types
    }

    private func sourceHint(for source: ThirdPartyImportSource) -> String {
        switch source {
        case .cherryStudio:
            return NSLocalizedString("支持 Cherry Studio 的 .json 或解压后的备份目录；若是 .zip / .bak，请先解压后再导入。", comment: "Cherry source hint")
        case .rikkahub:
            return NSLocalizedString("支持 RikkaHub 的 settings.json（可直接选文件或解压目录，当前先导入提供商配置）。", comment: "Rikka source hint")
        case .kelivo:
            return NSLocalizedString("支持 Kelivo 的 settings.json + chats.json（建议选择解压后的目录一次导入）。", comment: "Kelivo source hint")
        case .chatgpt:
            return NSLocalizedString("支持 ChatGPT 官方 conversations.json（可直接选文件或包含该文件的目录）。", comment: "ChatGPT source hint")
        }
    }

    private func handleFileSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            selectedFileName = fileURL.lastPathComponent
            startImport(fileURL: fileURL, source: selectedSource)

        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func startImport(fileURL: URL, source: ThirdPartyImportSource) {
        isImporting = true
        importError = nil

        Task {
            do {
                let report = try await ThirdPartyImportService.importAndApply(
                    source: source,
                    fileURL: fileURL
                )
                await MainActor.run {
                    importReport = report
                    isImporting = false
                }
            } catch {
                await MainActor.run {
                    importError = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
