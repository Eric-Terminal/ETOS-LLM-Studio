// ============================================================================
// StorageManagementView.swift
// ============================================================================
// ETOS LLM Studio Watch App - 存储管理视图
//
// 功能特性:
// - 显示 Documents 目录的存储使用概览
// - 按类别浏览文件
// - 提供缓存清理功能
// ============================================================================

import SwiftUI
import Shared

public struct StorageManagementView: View {
    @State private var storageBreakdown = StorageBreakdown()
    @State private var isLoading = true
    @State private var showClearCacheConfirmation = false
    @State private var showCleanOrphansConfirmation = false
    @State private var orphanedAudioCount = 0
    @State private var orphanedImageCount = 0
    @State private var ghostSessionCount = 0
    @State private var showGhostSessionAlert = false
    @State private var ghostSessionMessage = ""
    @State private var cleanupAlert: CleanupAlert?
    
    struct CleanupAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    
    public init() {}
    
    public var body: some View {
        List {
            // 存储概览
            storageOverviewSection
            
            // 存储类别
            storageCategoriesSection
            
            // 清理工具
            cleanupToolsSection
        }
        .navigationTitle("存储管理")
        .task {
            await refreshData()
        }
        .confirmationDialog(
            "清理缓存",
            isPresented: $showClearCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button("清理", role: .destructive) {
                performCacheCleanup()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除所有语音和图片缓存文件。")
        }
        .confirmationDialog(
            "清理孤立文件",
            isPresented: $showCleanOrphansConfirmation,
            titleVisibility: .visible
        ) {
            Button("清理", role: .destructive) {
                performOrphanCleanup()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(String(format: NSLocalizedString("将删除 %d 个孤立文件。", comment: ""), orphanedAudioCount + orphanedImageCount))
        }
        .confirmationDialog(
            "幽灵会话",
            isPresented: $showGhostSessionAlert,
            titleVisibility: .visible
        ) {
            if ghostSessionCount > 0 {
                Button("清理", role: .destructive) {
                    cleanupGhostSessions()
                }
            }
            Button(ghostSessionCount > 0 ? "取消" : "好的", role: .cancel) {}
        } message: {
            Text(ghostSessionMessage)
        }
        .alert(item: $cleanupAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好的"))
            )
        }
    }
    
    // MARK: - 存储概览
    
    private var storageOverviewSection: some View {
        Section {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "internaldrive")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    
                    Text(StorageUtility.formatSize(storageBreakdown.totalSize))
                        .font(.headline)
                    
                    Text("总使用空间")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }
    
    // MARK: - 存储类别
    
    private var storageCategoriesSection: some View {
        Section("存储分类") {
            ForEach(StorageCategory.allCases) { category in
                NavigationLink {
                    WatchFileListView(category: category)
                } label: {
                    HStack {
                        Image(systemName: category.systemImage)
                            .foregroundStyle(category.iconColor)
                            .frame(width: 20)
                        
                        Text(category.displayName)
                            .font(.footnote)
                        
                        Spacer()
                        
                        Text(StorageUtility.formatSize(storageBreakdown.categorySize[category] ?? 0))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    
    // MARK: - 清理工具
    
    private var cleanupToolsSection: some View {
        Section("清理工具") {
            Button {
                checkOrphanedFiles()
            } label: {
                HStack {
                    Image(systemName: "trash.slash")
                        .foregroundStyle(.orange)
                    Text("清理孤立文件")
                        .font(.footnote)
                    Spacer()
                    if orphanedAudioCount + orphanedImageCount > 0 {
                        Text("\(orphanedAudioCount + orphanedImageCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // 👻 幽灵会话检测
            Button {
                checkGhostSessions()
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text("检测幽灵会话")
                        .font(.footnote)
                    Spacer()
                    if ghostSessionCount > 0 {
                        HStack(spacing: 2) {
                            Text("👻")
                            Text("\(ghostSessionCount)")
                        }
                        .font(.caption2)
                    }
                }
            }
            
            Button(role: .destructive) {
                showClearCacheConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("清理所有缓存")
                        .font(.footnote)
                }
            }
        }
    }
    
    // MARK: - 操作方法
    
    private func refreshData() async {
        isLoading = true
        
        let breakdown = await Task.detached(priority: .userInitiated) {
            StorageUtility.getStorageBreakdown()
        }.value
        
        let orphanedAudio = await Task.detached(priority: .userInitiated) {
            StorageUtility.findOrphanedAudioFiles().count
        }.value
        
        let orphanedImages = await Task.detached(priority: .userInitiated) {
            StorageUtility.findOrphanedImageFiles().count
        }.value
        
        let ghostCount = await Task.detached(priority: .userInitiated) {
            StorageUtility.findGhostSessions().count
        }.value
        
        await MainActor.run {
            storageBreakdown = breakdown
            orphanedAudioCount = orphanedAudio
            orphanedImageCount = orphanedImages
            ghostSessionCount = ghostCount
            isLoading = false
        }
    }
    
    private func checkOrphanedFiles() {
        if orphanedAudioCount + orphanedImageCount > 0 {
            showCleanOrphansConfirmation = true
        } else {
            cleanupAlert = CleanupAlert(
                title: "无孤立文件",
                message: "没有需要清理的孤立文件。"
            )
        }
    }
    
    private func checkGhostSessions() {
        ghostSessionMessage = StorageUtility.getGhostSessionEasterEggMessage(count: ghostSessionCount)
        showGhostSessionAlert = true
    }
    
    private func cleanupGhostSessions() {
        Task {
            let count = await Task.detached(priority: .userInitiated) {
                StorageUtility.cleanupGhostSessions()
            }.value
            
            await MainActor.run {
                cleanupAlert = CleanupAlert(
                    title: "👻 驱鬼成功",
                    message: String(format: NSLocalizedString("已清理 %d 个幽灵会话。", comment: ""), count)
                )
            }
            
            await refreshData()
        }
    }
    
    private func performCacheCleanup() {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                StorageUtility.clearCacheFiles()
            }.value
            
            await MainActor.run {
                cleanupAlert = CleanupAlert(
                    title: "清理完成",
                    message: String(format: NSLocalizedString("已删除 %d 个文件。", comment: ""), result.audioDeleted + result.imageDeleted)
                )
            }
            
            await refreshData()
        }
    }
    
    private func performOrphanCleanup() {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                StorageUtility.cleanupOrphanedFiles()
            }.value
            
            await MainActor.run {
                cleanupAlert = CleanupAlert(
                    title: "清理完成",
                    message: String(format: NSLocalizedString("已删除 %d 个孤立文件。", comment: ""), result.audioDeleted + result.imageDeleted)
                )
            }
            
            await refreshData()
        }
    }
}

// MARK: - 文件列表视图

public struct WatchFileListView: View {
    let category: StorageCategory
    
    @State private var files: [FileItem] = []
    @State private var isLoading = true
    @State private var fileToDelete: FileItem?
    @State private var showDeleteConfirmation = false
    
    public init(category: StorageCategory) {
        self.category = category
    }
    
    public var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: category.systemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无文件")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                fileListView
            }
        }
        .navigationTitle(category.displayName)
        .task {
            await loadFiles()
        }
        .confirmationDialog(
            "删除文件",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let file = fileToDelete {
                    deleteFile(file)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let file = fileToDelete {
                Text(String(format: NSLocalizedString("删除 \"%@\"？", comment: ""), file.name))
            }
        }
    }
    
    private var fileListView: some View {
        List {
            Section {
                HStack {
                    Text("文件数量")
                        .font(.footnote)
                    Spacer()
                    Text("\(files.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("总大小")
                        .font(.footnote)
                    Spacer()
                    Text(StorageUtility.formatSize(files.reduce(0) { $0 + $1.size }))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("文件") {
                ForEach(files) { file in
                    WatchFileRow(file: file)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                fileToDelete = file
                                showDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                }
            }
        }
    }
    
    private func loadFiles() async {
        isLoading = true
        
        let categoryToLoad = category  // 捕获值以避免 Swift 6 并发错误
        let loadedFiles = await Task.detached(priority: .userInitiated) {
            StorageUtility.listFiles(for: categoryToLoad)
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
                // 错误处理
            }
        }
    }
}

// MARK: - 文件行视图

private struct WatchFileRow: View {
    let file: FileItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.name)
                .font(.footnote)
                .lineLimit(1)
            
            HStack {
                Text(StorageUtility.formatSize(file.size))
                Text("•")
                Text(file.modificationDate.formatted(date: .abbreviated, time: .omitted))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 预览

#Preview {
    NavigationStack {
        StorageManagementView()
    }
}
