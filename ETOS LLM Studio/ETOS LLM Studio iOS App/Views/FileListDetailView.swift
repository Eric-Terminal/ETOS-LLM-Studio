// ============================================================================
// FileListDetailView.swift
// ============================================================================
// ETOS LLM Studio iOS App - 文件列表详情视图
//
// 功能特性:
// - 按目录层级浏览文件与文件夹
// - 显示文件名、大小、修改时间，并为长文件名提供跑马灯
// - 支持删除单个文件和批量删除
// - 支持 JSON 文件预览
// ============================================================================

import SwiftUI
import Shared

struct FileListDetailView: View {
    let category: StorageCategory

    private let rootDirectory: URL

    init(category: StorageCategory) {
        self.category = category
        self.rootDirectory = StorageUtility.getDirectory(for: category)
    }

    var body: some View {
        StorageDirectoryBrowserView(
            title: category.displayName,
            rootDirectory: rootDirectory,
            currentDirectory: rootDirectory,
            emptyTitle: "暂无文件",
            emptyDescription: "此类别下没有任何文件。",
            footerText: "点击文件夹继续浏览，点击 JSON 文件可预览内容。"
        )
    }
}

private struct StorageDirectoryBrowserView: View {
    let title: String
    let rootDirectory: URL
    let currentDirectory: URL
    let emptyTitle: String
    let emptyDescription: String
    let footerText: String?
    let itemFilter: (FileItem) -> Bool

    @State private var files: [FileItem] = []
    @State private var isLoading = true
    @State private var selectedFiles = Set<String>()
    @State private var isEditing = false
    @State private var showDeleteAlert = false
    @State private var fileToDelete: FileItem?
    @State private var showBatchDeleteAlert = false
    @State private var previewingFile: FileItem?

    init(
        title: String,
        rootDirectory: URL,
        currentDirectory: URL,
        emptyTitle: String,
        emptyDescription: String,
        footerText: String? = nil,
        itemFilter: @escaping (FileItem) -> Bool = { _ in true }
    ) {
        self.title = title
        self.rootDirectory = rootDirectory
        self.currentDirectory = currentDirectory
        self.emptyTitle = emptyTitle
        self.emptyDescription = emptyDescription
        self.footerText = footerText
        self.itemFilter = itemFilter
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

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "folder",
                    description: Text(emptyDescription)
                )
            } else {
                fileListView
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !files.isEmpty {
                    Button(isEditing ? "完成" : "编辑") {
                        withAnimation {
                            isEditing.toggle()
                            if !isEditing {
                                selectedFiles.removeAll()
                            }
                        }
                    }
                }
            }
        }
        .task {
            await loadFiles()
        }
        .refreshable {
            await loadFiles()
        }
        .alert("删除文件", isPresented: $showDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let file = fileToDelete {
                    deleteFile(file)
                }
            }
        } message: {
            if let file = fileToDelete {
                Text(String(format: NSLocalizedString("确定要删除 \"%@\" 吗？此操作不可撤销。", comment: ""), file.name))
            }
        }
        .alert("批量删除", isPresented: $showBatchDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button(String(format: NSLocalizedString("删除 %d 个项目", comment: ""), selectedFiles.count), role: .destructive) {
                deleteSelectedFiles()
            }
        } message: {
            Text(String(format: NSLocalizedString("确定要删除选中的 %d 个项目吗？此操作不可撤销。", comment: ""), selectedFiles.count))
        }
        .sheet(item: $previewingFile) { file in
            FilePreviewSheet(file: file)
        }
    }

    private var fileListView: some View {
        List(selection: $selectedFiles) {
            Section("当前位置") {
                Text(relativePath)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            Section("统计") {
                infoRow(title: "文件夹", value: "\(folderCount)")
                infoRow(title: "文件", value: "\(fileCount)")
                infoRow(title: "可见项目", value: "\(files.count)")
                infoRow(title: "文件总大小", value: StorageUtility.formatSize(totalFileSize))
            }

            Section {
                ForEach(files) { file in
                    row(for: file)
                }
            } header: {
                Text("内容")
            } footer: {
                if let footerText {
                    Text(footerText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .safeAreaInset(edge: .bottom) {
            if isEditing && !selectedFiles.isEmpty {
                batchDeleteButton
            }
        }
    }

    private var batchDeleteButton: some View {
        Button(role: .destructive) {
            showBatchDeleteAlert = true
        } label: {
            HStack {
                Image(systemName: "trash")
                Text(String(format: NSLocalizedString("删除 %d 个项目", comment: ""), selectedFiles.count))
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.red)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func row(for file: FileItem) -> some View {
        if isEditing {
            FileRowView(file: file, isEditing: true, isSelected: selectedFiles.contains(file.id))
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleSelection(file)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    deleteAction(for: file)
                }
        } else if file.isDirectory {
            NavigationLink {
                StorageDirectoryBrowserView(
                    title: file.name,
                    rootDirectory: rootDirectory,
                    currentDirectory: file.url,
                    emptyTitle: "空文件夹",
                    emptyDescription: "这个文件夹里还没有内容。",
                    footerText: footerText,
                    itemFilter: itemFilter
                )
            } label: {
                FileRowView(file: file, isEditing: false, isSelected: false)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                deleteAction(for: file)
            }
        } else if StorageBrowserSupport.isJSONFile(file.url) {
            Button {
                previewingFile = file
            } label: {
                FileRowView(file: file, isEditing: false, isSelected: false)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                deleteAction(for: file)
            }
        } else {
            FileRowView(file: file, isEditing: false, isSelected: false)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    deleteAction(for: file)
                }
        }
    }

    private func deleteAction(for file: FileItem) -> some View {
        Button(role: .destructive) {
            fileToDelete = file
            showDeleteAlert = true
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
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
            files = loadedFiles.filter(itemFilter)
            isLoading = false
        }
    }

    private func toggleSelection(_ file: FileItem) {
        if selectedFiles.contains(file.id) {
            selectedFiles.remove(file.id)
        } else {
            selectedFiles.insert(file.id)
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
                // 当前界面暂不展示额外错误提示，保持与现有存储管理交互一致。
            }
        }
    }

    private func deleteSelectedFiles() {
        Task {
            let urlsToDelete = files.filter { selectedFiles.contains($0.id) }.map(\.url)
            _ = StorageUtility.deleteFiles(urlsToDelete)

            await MainActor.run {
                files.removeAll { selectedFiles.contains($0.id) }
                selectedFiles.removeAll()
                isEditing = false
            }
        }
    }
}

private struct FileRowView: View {
    let file: FileItem
    let isEditing: Bool
    let isSelected: Bool

    private var subtitle: String {
        let date = file.modificationDate.formatted(date: .abbreviated, time: .shortened)
        if file.isDirectory {
            return "文件夹 • \(date)"
        }
        return "\(StorageUtility.formatSize(file.size)) • \(date)"
    }

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.title3)
            }

            fileIcon

            MarqueeTitleSubtitleLabel(
                title: file.name,
                subtitle: subtitle,
                titleUIFont: .preferredFont(forTextStyle: .subheadline),
                subtitleUIFont: .preferredFont(forTextStyle: .caption1),
                subtitleColor: .secondary,
                spacing: 4
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if StorageBrowserSupport.isJSONFile(file.url) && !isEditing {
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var fileIcon: some View {
        let (icon, color) = fileIconInfo

        return Image(systemName: icon)
            .font(.system(size: 16))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var fileIconInfo: (String, Color) {
        if file.isDirectory {
            return ("folder.fill", .blue)
        }

        let ext = file.url.pathExtension.lowercased()
        switch ext {
        case "json":
            return ("doc.text", .orange)
        case "m4a", "mp3", "wav", "aac":
            return ("waveform", .purple)
        case "jpg", "jpeg", "png", "gif", "webp", "heic":
            return ("photo", .green)
        case "pdf":
            return ("doc.richtext", .red)
        default:
            return ("doc", .gray)
        }
    }
}

private struct FilePreviewSheet: View {
    let file: FileItem

    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var isLoading = true

    private var lineCount: Int {
        guard let content else { return 0 }
        return StorageBrowserSupport.paginateText(content, linesPerPage: Int.max).first?.endLineNumber ?? 0
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let content {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("文件名")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(file.name)
                                    .font(.footnote.monospaced())

                                Text("总行数")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(lineCount)")
                                    .font(.footnote.monospaced())
                            }

                            Text(content)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "无法预览",
                        systemImage: "doc.questionmark",
                        description: Text("无法读取此文件的内容。")
                    )
                }
            }
            .navigationTitle("JSON 预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            content = StorageUtility.readJSONFile(at: file.url)
            isLoading = false
        }
    }
}

struct OtherFilesView: View {
    private let rootDirectory = StorageUtility.documentsDirectory
    private let knownDirectories = Set(StorageCategory.allCases.map(\.rawValue))

    var body: some View {
        StorageDirectoryBrowserView(
            title: "其他文件",
            rootDirectory: rootDirectory,
            currentDirectory: rootDirectory,
            emptyTitle: "暂无其他文件",
            emptyDescription: "Documents 根目录下没有其他文件。",
            footerText: "点击文件夹继续浏览，点击 JSON 文件可预览内容。",
            itemFilter: { item in
                if item.isDirectory {
                    return !knownDirectories.contains(item.name)
                }
                return true
            }
        )
    }
}
