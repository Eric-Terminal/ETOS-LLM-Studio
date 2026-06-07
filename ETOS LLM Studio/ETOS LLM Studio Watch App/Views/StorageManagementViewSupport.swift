// ============================================================================
// StorageManagementViewSupport.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 存储管理视图的文件浏览、文本预览、图片预览、SQLite 预览与文件行辅助。
// ============================================================================

import SwiftUI
import ETOSCore

struct DocumentsStorageBrowserView: View {
    private let rootDirectory = StorageUtility.documentsDirectory

    var body: some View {
        WatchFileListView(
            category: .sessions,
            directoryURL: rootDirectory,
            rootDirectory: rootDirectory,
            title: rootDirectory.lastPathComponent
        )
    }
}

public struct WatchFileListView: View {
    let category: StorageCategory

    private let rootDirectory: URL
    private let currentDirectory: URL
    private let titleOverride: String?

    @State private var files: [FileItem] = []
    @State private var isLoading = true
    @State private var fileToDelete: FileItem?
    @State private var showDeleteConfirmation = false

    public init(
        category: StorageCategory,
        directoryURL: URL? = nil,
        rootDirectory: URL? = nil,
        title: String? = nil
    ) {
        self.category = category
        let root = rootDirectory ?? StorageUtility.getDirectory(for: category)
        self.rootDirectory = root
        self.currentDirectory = directoryURL ?? root
        self.titleOverride = title
    }

    private var relativePath: String {
        StorageBrowserSupport.relativeDisplayPath(for: currentDirectory, rootDirectory: rootDirectory)
    }

    private var folderCount: Int {
        files.filter(\.isDirectory).count
    }

    private var fileCount: Int {
        files.count - folderCount
    }

    private var totalFileSize: Int64 {
        files.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }
    }

    public var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .etFont(.title2)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("暂无内容", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                fileListView
            }
        }
        .navigationTitle(currentDirectory == rootDirectory ? (titleOverride ?? category.displayName) : currentDirectory.lastPathComponent)
        .task {
            await loadFiles()
        }
        .confirmationDialog(NSLocalizedString("删除项目", comment: ""),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let file = fileToDelete {
                    deleteFile(file)
                }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            if let file = fileToDelete {
                Text(String(format: NSLocalizedString("删除 \"%@\"？", comment: ""), file.name))
            }
        }
    }

    private var fileListView: some View {
        List {
            Section(NSLocalizedString("当前位置", comment: "")) {
                Text(relativePath)
                    .etFont(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("统计", comment: "")) {
                infoRow(title: NSLocalizedString("文件夹", comment: ""), value: "\(folderCount)")
                infoRow(title: NSLocalizedString("文件", comment: ""), value: "\(fileCount)")
                infoRow(title: NSLocalizedString("总大小", comment: ""), value: StorageUtility.formatSize(totalFileSize))
            }

            Section {
                ForEach(files) { file in
                    row(for: file)
                }
            } header: {
                Text(NSLocalizedString("内容", comment: ""))
            } footer: {
                Text(NSLocalizedString("点击文件夹继续浏览，点击文件可尝试预览内容。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(for file: FileItem) -> some View {
        if file.isDirectory {
            NavigationLink {
                WatchFileListView(
                    category: category,
                    directoryURL: file.url,
                    rootDirectory: rootDirectory,
                    title: titleOverride
                )
            } label: {
                WatchFileRow(file: file)
            }
            .swipeActions(edge: .trailing) {
                deleteAction(for: file)
            }
        } else if StorageBrowserSupport.isImageFile(file.url) {
            NavigationLink {
                WatchImagePreviewView(file: file)
            } label: {
                WatchFileRow(file: file)
            }
            .swipeActions(edge: .trailing) {
                deleteAction(for: file)
            }
        } else if StorageBrowserSupport.isSQLiteDatabaseFile(file.url) {
            NavigationLink {
                WatchSQLitePreviewView(file: file)
            } label: {
                WatchFileRow(file: file)
            }
            .swipeActions(edge: .trailing) {
                deleteAction(for: file)
            }
        } else {
            NavigationLink {
                WatchFilePreviewView(file: file)
            } label: {
                WatchFileRow(file: file)
            }
            .swipeActions(edge: .trailing) {
                deleteAction(for: file)
            }
        }
    }

    private func deleteAction(for file: FileItem) -> some View {
        Button(role: .destructive) {
            fileToDelete = file
            showDeleteConfirmation = true
        } label: {
            Image(systemName: "trash")
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(NSLocalizedString(title, comment: "存储信息行标题"))
                .etFont(.footnote)
            Spacer()
            Text(value)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func loadFiles() async {
        isLoading = true

        let directory = currentDirectory
        let loadedFiles = await Task.detached(priority: .userInitiated) {
            StorageUtility.listFiles(in: directory)
        }.value

        await MainActor.run {
            files = loadedFiles
            isLoading = false
        }
    }

    private func deleteFile(_ file: FileItem) {
        Task {
            do {
                try StorageUtility.deleteFile(at: file.url)
                await MainActor.run {
                    files.removeAll { $0.id == file.id }
                }
            } catch {
                // 当前界面暂不展示额外错误提示，保持与现有交互一致。
            }
        }
    }
}


private struct WatchFileRow: View {
    let file: FileItem

    private var subtitle: String {
        let date = file.modificationDate.formatted(date: .abbreviated, time: .omitted)
        if file.isDirectory {
            return String(format: NSLocalizedString("文件夹 • %@", comment: ""), date)
        }
        return "\(StorageUtility.formatSize(file.size)) • \(date)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                MarqueeText(
                    content: file.name,
                    uiFont: .preferredFont(forTextStyle: .footnote),
                    speed: 28,
                    delay: 0.8,
                    spacing: 24
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(subtitle)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        if file.isDirectory {
            return "folder.fill"
        }
        if StorageBrowserSupport.isImageFile(file.url) {
            return "photo"
        }
        if StorageBrowserSupport.isSQLiteDatabaseFile(file.url) {
            return "cylinder.split.1x2"
        }
        switch file.url.pathExtension.lowercased() {
        case "json", "jsonl", "txt", "text", "md", "markdown", "csv", "tsv", "log", "xml", "html", "htm", "yaml", "yml":
            return "doc.text"
        case "m4a", "mp3", "wav", "aac":
            return "waveform"
        default:
            return "doc"
        }
    }

    private var iconColor: Color {
        if file.isDirectory {
            return .blue
        }
        if StorageBrowserSupport.isImageFile(file.url) {
            return .green
        }
        if StorageBrowserSupport.isSQLiteDatabaseFile(file.url) {
            return .indigo
        }
        switch file.url.pathExtension.lowercased() {
        case "json", "jsonl", "txt", "text", "md", "markdown", "csv", "tsv", "log", "xml", "html", "htm", "yaml", "yml":
            return .orange
        case "m4a", "mp3", "wav", "aac":
            return .purple
        default:
            return .secondary
        }
    }
}

private struct WatchFilePreviewView: View {
    let file: FileItem

    @State private var pages: [StorageTextPage] = []
    @State private var isLoading = true
    @State private var selectedPageIndex = 0
    @State private var previewErrorMessage: String?

    private var currentPage: StorageTextPage? {
        guard pages.indices.contains(selectedPageIndex) else { return nil }
        return pages[selectedPageIndex]
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let currentPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        summaryCard(for: currentPage)
                        if pages.count > 1 {
                            pageControls
                        }

                        Text(currentPage.content)
                            .etFont(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                            )

                        if pages.count > 1 {
                            pageControls
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark")
                        .etFont(.title3)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("无法预览", comment: ""))
                        .etFont(.footnote)
                    Text(previewErrorMessage ?? NSLocalizedString("无法读取此文件的内容。", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(file.name)
        .task {
            await loadPages()
        }
    }

    private func summaryCard(for page: StorageTextPage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: NSLocalizedString("第 %d / %d 页", comment: ""), page.index + 1, page.totalCount))
                .etFont(.footnote.weight(.semibold))
            Text(String(format: NSLocalizedString("第 %d-%d 行", comment: ""), page.startLineNumber, page.endLineNumber))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var pageControls: some View {
        HStack(spacing: 8) {
            Button(NSLocalizedString("上一页", comment: "")) {
                selectedPageIndex = max(selectedPageIndex - 1, 0)
            }
            .disabled(selectedPageIndex == 0)

            Button(NSLocalizedString("下一页", comment: "")) {
                selectedPageIndex = min(selectedPageIndex + 1, max(0, pages.count - 1))
            }
            .disabled(selectedPageIndex >= pages.count - 1)
        }
        .etFont(.caption2)
    }

    private func loadPages() async {
        isLoading = true

        let fileURL = file.url
        let result = await Task.detached(priority: .userInitiated) {
            let payload = FileAttachmentPreviewLoader.load(fileURL: fileURL)
            guard let content = payload.text else {
                return (pages: [StorageTextPage](), errorMessage: payload.errorMessage)
            }
            return (
                pages: StorageBrowserSupport.paginateText(content, linesPerPage: 100),
                errorMessage: payload.errorMessage
            )
        }.value

        await MainActor.run {
            pages = result.pages
            previewErrorMessage = result.errorMessage
            selectedPageIndex = 0
            isLoading = false
        }
    }
}

#Preview {
    NavigationStack {
        StorageManagementView()
    }
}
