// ============================================================================
// StorageManagementView.swift
// ============================================================================
// ETOS LLM Studio iOS App - 存储管理视图
//
// 功能特性:
// - 显示 Documents 目录的存储使用概览
// - 按类别浏览文件
// - 提供缓存清理和孤立文件清理功能
// ============================================================================

import SwiftUI
import Shared

struct StorageManagementView: View {
    @State private var storageBreakdown = StorageBreakdown()
    @State private var isLoading = true
    @State private var showClearCacheAlert = false
    @State private var showCleanAllOrphansAlert = false
    @State private var orphanedDataCount = StorageUtility.OrphanedDataCount(ghostSessions: 0, orphanedAudioFiles: 0, orphanedImageFiles: 0, orphanedAudioReferences: 0)
    @State private var cleanupResult: CleanupResult?
    
    struct CleanupResult: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    
    var body: some View {
        List {
            // 存储概览
            storageOverviewSection
            
            // 按类别浏览
            storageCategoriesSection
            
            // 清理工具
            cleanupToolsSection
        }
        .navigationTitle("存储管理")
        .refreshable {
            await refreshData()
        }
        .task {
            await refreshData()
        }
        .alert("清理缓存", isPresented: $showClearCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                performCacheCleanup()
            }
        } message: {
            Text("将删除所有语音和图片缓存文件。此操作不可撤销。")
        }
        .alert(item: $cleanupResult) { result in
            Alert(
                title: Text(result.title),
                message: Text(result.message),
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
                        .padding()
                    Spacer()
                }
            } else {
                VStack(alignment: .center, spacing: 12) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                    
                    VStack(spacing: 4) {
                        Text("总使用空间")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(StorageUtility.formatSize(storageBreakdown.totalSize))
                            .font(.title.weight(.bold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
        }
    }
    
    // MARK: - 存储类别
    
    private var storageCategoriesSection: some View {
        Section {
            ForEach(StorageCategory.allCases) { category in
                NavigationLink {
                    FileListDetailView(category: category)
                } label: {
                    StorageCategoryRow(
                        category: category,
                        size: storageBreakdown.categorySize[category] ?? 0,
                        totalSize: storageBreakdown.totalSize
                    )
                }
            }
            
            // 其他文件
            if storageBreakdown.otherSize > 0 {
                NavigationLink {
                    OtherFilesView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc")
                            .font(.system(size: 18))
                            .foregroundStyle(.gray)
                            .frame(width: 32, height: 32)
                            .background(Color.gray.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("其他文件")
                                .font(.subheadline.weight(.medium))
                            Text(StorageUtility.formatSize(storageBreakdown.otherSize))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("存储分类")
        } footer: {
            Text("点击类别可查看详细文件列表。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - 清理工具
    
    private var cleanupToolsSection: some View {
        Section {
            // 统一清理孤立数据
            Button {
                checkAllOrphanedData()
            } label: {
                HStack {
                    Label("清理孤立数据", systemImage: "trash.slash")
                    Spacer()
                    if orphanedDataCount.total > 0 {
                        Text(String(format: NSLocalizedString("%d 项", comment: ""), orphanedDataCount.total))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // 清理缓存
            Button(role: .destructive) {
                showClearCacheAlert = true
            } label: {
                Label("清理所有缓存", systemImage: "trash")
            }
        } header: {
            Text("清理工具")
        } footer: {
            Text("孤立数据包括：幽灵会话（消息文件丢失）、孤立音频/图片文件（无会话引用）、无效音频引用（文件已删除）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "确认清理孤立数据",
            isPresented: $showCleanAllOrphansAlert,
            titleVisibility: .visible
        ) {
            Button("清理", role: .destructive) {
                performAllOrphanCleanup()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理：\(orphanedDataCount.description)。\n\n此操作不可撤销。")
        }
    }
    
    // MARK: - 操作方法
    
    private func refreshData() async {
        isLoading = true
        
        // 在后台线程计算存储信息
        let breakdown = await Task.detached(priority: .userInitiated) {
            StorageUtility.getStorageBreakdown()
        }.value
        
        let orphanedCount = await Task.detached(priority: .userInitiated) {
            StorageUtility.countAllOrphanedData()
        }.value
        
        await MainActor.run {
            storageBreakdown = breakdown
            orphanedDataCount = orphanedCount
            isLoading = false
        }
    }
    
    private func checkAllOrphanedData() {
        if orphanedDataCount.total > 0 {
            showCleanAllOrphansAlert = true
        } else {
            cleanupResult = CleanupResult(
                title: "无孤立数据",
                message: "当前没有需要清理的孤立数据。"
            )
        }
    }
    
    private func performAllOrphanCleanup() {
        Task {
            let summary = await Task.detached(priority: .userInitiated) {
                StorageUtility.cleanupAllOrphans()
            }.value
            
            await MainActor.run {
                cleanupResult = CleanupResult(
                    title: "清理完成",
                    message: "已清理：\(summary.description)"
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
                cleanupResult = CleanupResult(
                    title: "清理完成",
                    message: String(format: NSLocalizedString("已删除 %d 个语音文件和 %d 个图片文件。", comment: ""), result.audioDeleted, result.imageDeleted)
                )
            }
            
            await refreshData()
        }
    }
}

// MARK: - 存储类别行

private struct StorageCategoryRow: View {
    let category: StorageCategory
    let size: Int64
    let totalSize: Int64
    
    private var percentage: Double {
        guard totalSize > 0 else { return 0 }
        return Double(size) / Double(totalSize)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(category.iconColor)
                .frame(width: 32, height: 32)
                .background(category.iconColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName)
                    .font(.subheadline.weight(.medium))
                
                HStack(spacing: 8) {
                    Text(StorageUtility.formatSize(size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    if percentage > 0.01 {
                        Text(String(format: "%.1f%%", percentage * 100))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 预览

#Preview {
    NavigationStack {
        StorageManagementView()
    }
}
