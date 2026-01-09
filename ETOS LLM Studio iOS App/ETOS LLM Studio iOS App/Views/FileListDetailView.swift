// ============================================================================
// FileListDetailView.swift
// ============================================================================
// ETOS LLM Studio iOS App - 文件列表详情视图
//
// 功能特性:
// - 显示指定类别的所有文件
// - 显示文件名、大小、修改时间
// - 支持删除单个文件和批量删除
// - 支持 JSON 文件预览
// ============================================================================

import SwiftUI
import Shared

struct FileListDetailView: View {
    let category: StorageCategory
    
    @State private var files: [FileItem] = []
    @State private var isLoading = true
    @State private var selectedFiles = Set<String>()
    @State private var isEditing = false
    @State private var showDeleteAlert = false
    @State private var fileToDelete: FileItem?
    @State private var showBatchDeleteAlert = false
    @State private var previewingFile: FileItem?
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                ContentUnavailableView(
                    "暂无文件",
                    systemImage: category.systemImage,
                    description: Text("此类别下没有任何文件。")
                )
            } else {
                fileListView
            }
        }
        .navigationTitle(category.displayName)
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
                Text("确定要删除 \"\(file.name)\" 吗？此操作不可撤销。")
            }
        }
        .alert("批量删除", isPresented: $showBatchDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除 \(selectedFiles.count) 个文件", role: .destructive) {
                deleteSelectedFiles()
            }
        } message: {
            Text("确定要删除选中的 \(selectedFiles.count) 个文件吗？此操作不可撤销。")
        }
        .sheet(item: $previewingFile) { file in
            FilePreviewSheet(file: file)
        }
    }
    
    // MARK: - 文件列表视图
    
    private var fileListView: some View {
        List(selection: $selectedFiles) {
            // 统计信息
            Section {
                HStack {
                    Text("文件数量")
                    Spacer()
                    Text("\(files.count)")
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("总大小")
                    Spacer()
                    Text(StorageUtility.formatSize(files.reduce(0) { $0 + $1.size }))
                        .foregroundStyle(.secondary)
                }
            }
            
            // 文件列表
            Section {
                ForEach(files) { file in
                    FileRowView(file: file, isEditing: isEditing, isSelected: selectedFiles.contains(file.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isEditing {
                                toggleSelection(file)
                            } else if file.name.hasSuffix(".json") {
                                previewingFile = file
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                fileToDelete = file
                                showDeleteAlert = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                Text("文件列表")
            } footer: {
                if files.first?.name.hasSuffix(".json") == true {
                    Text("点击 JSON 文件可预览内容。")
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
    
    // MARK: - 批量删除按钮
    
    private var batchDeleteButton: some View {
        Button(role: .destructive) {
            showBatchDeleteAlert = true
        } label: {
            HStack {
                Image(systemName: "trash")
                Text("删除 \(selectedFiles.count) 个文件")
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
    
    // MARK: - 操作方法
    
    private func loadFiles() async {
        isLoading = true
        let categoryToLoad = category
        
        let loadedFiles = await Task.detached(priority: .userInitiated) {
            StorageUtility.listFiles(for: categoryToLoad)
        }.value
        
        await MainActor.run {
            files = loadedFiles
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
                // 错误处理
            }
        }
    }
    
    private func deleteSelectedFiles() {
        Task {
            let urlsToDelete = files.filter { selectedFiles.contains($0.id) }.map { $0.url }
            _ = StorageUtility.deleteFiles(urlsToDelete)
            
            await MainActor.run {
                files.removeAll { selectedFiles.contains($0.id) }
                selectedFiles.removeAll()
                isEditing = false
            }
        }
    }
}

// MARK: - 文件行视图

private struct FileRowView: View {
    let file: FileItem
    let isEditing: Bool
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.title3)
            }
            
            fileIcon
            
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(StorageUtility.formatSize(file.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    Text(file.modificationDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if file.name.hasSuffix(".json") && !isEditing {
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var fileIcon: some View {
        let (icon, color) = fileIconInfo
        
        Image(systemName: icon)
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
        
        let ext = (file.name as NSString).pathExtension.lowercased()
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

// MARK: - JSON 文件预览

private struct FilePreviewSheet: View {
    let file: FileItem
    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var isLoading = true
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let content = content {
                    ScrollView {
                        Text(content)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ContentUnavailableView(
                        "无法预览",
                        systemImage: "doc.questionmark",
                        description: Text("无法读取此文件的内容。")
                    )
                }
            }
            .navigationTitle(file.name)
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

// MARK: - 其他文件视图

struct OtherFilesView: View {
    @State private var files: [FileItem] = []
    @State private var isLoading = true
    @State private var fileToDelete: FileItem?
    @State private var showDeleteAlert = false
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                ContentUnavailableView(
                    "暂无其他文件",
                    systemImage: "doc",
                    description: Text("Documents 根目录下没有其他文件。")
                )
            } else {
                List {
                    ForEach(files) { file in
                        FileRowView(file: file, isEditing: false, isSelected: false)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    fileToDelete = file
                                    showDeleteAlert = true
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("其他文件")
        .task {
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
                Text("确定要删除 \"\(file.name)\" 吗？此操作不可撤销。")
            }
        }
    }
    
    private func loadFiles() async {
        isLoading = true
        
        let allFiles = await Task.detached(priority: .userInitiated) {
            StorageUtility.listDocumentsRoot()
        }.value
        
        // 过滤掉已知类别的目录
        let knownDirectories = Set(StorageCategory.allCases.map { $0.rawValue })
        let otherFiles = allFiles.filter { file in
            if file.isDirectory {
                return !knownDirectories.contains(file.name)
            }
            return true
        }
        
        await MainActor.run {
            files = otherFiles
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
                // 错误处理
            }
        }
    }
}

// MARK: - 预览

#Preview {
    NavigationStack {
        FileListDetailView(category: .sessions)
    }
}
