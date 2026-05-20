// ============================================================================
// StorageManagementView.swift
// ============================================================================
// ETOS LLM Studio Watch App - 存储管理视图
//
// 功能特性:
// - 显示 Documents 目录的存储使用概览
// - 按类别浏览文件，并支持继续进入子文件夹
// - 支持文本文件分页预览、图片预览和 SQLite 数据库查询
// - 提供缓存清理功能
// ============================================================================

import SwiftUI
import Shared

public struct StorageManagementView: View {
    @State private var storageBreakdown = StorageBreakdown()
    @State private var isLoading = true
    @State private var showClearCacheConfirmation = false
    @State private var showCleanAllOrphansConfirmation = false
    @State private var orphanedDataCount = StorageUtility.OrphanedDataCount()
    @State private var cleanupAlert: CleanupAlert?

    struct CleanupAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    public init() {}

    public var body: some View {
        List {
            storageOverviewSection
            storageCategoriesSection
            cleanupToolsSection
        }
        .navigationTitle(NSLocalizedString("存储管理", comment: ""))
        .task {
            await refreshData()
        }
        .confirmationDialog(NSLocalizedString("清理缓存", comment: ""),
            isPresented: $showClearCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("清理", comment: ""), role: .destructive) {
                performCacheCleanup()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("将删除所有语音和图片缓存文件。", comment: ""))
        }
        .confirmationDialog(NSLocalizedString("确认清理孤立数据", comment: ""),
            isPresented: $showCleanAllOrphansConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("清理", comment: ""), role: .destructive) {
                performAllOrphanCleanup()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            Text(String(format: NSLocalizedString("将清理：%@。\n\n此操作不可撤销。", comment: ""), orphanedDataCount.description))
        }
        .alert(item: $cleanupAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(NSLocalizedString("好的", comment: "")))
            )
        }
    }

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
                        .etFont(.title2)
                        .foregroundStyle(.blue)

                    Text(StorageUtility.formatSize(storageBreakdown.totalSize))
                        .etFont(.headline)

                    Text(NSLocalizedString("总使用空间", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    private var storageCategoriesSection: some View {
        Section(NSLocalizedString("存储分类", comment: "")) {
            NavigationLink {
                DocumentsStorageBrowserView()
            } label: {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.blue)
                        .frame(width: 20)

                    Text(StorageUtility.documentsDirectory.lastPathComponent)
                        .etFont(.footnote)

                    Spacer()

                    Text(StorageUtility.formatSize(storageBreakdown.totalSize))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(StorageCategory.allCases) { category in
                NavigationLink {
                    WatchFileListView(category: category)
                } label: {
                    HStack {
                        Image(systemName: category.systemImage)
                            .foregroundStyle(category.iconColor)
                            .frame(width: 20)

                        Text(category.displayName)
                            .etFont(.footnote)

                        Spacer()

                        Text(StorageUtility.formatSize(storageBreakdown.categorySize[category] ?? 0))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var cleanupToolsSection: some View {
        Section {
            Button {
                checkAllOrphanedData()
            } label: {
                HStack {
                    Image(systemName: "trash.slash")
                        .foregroundStyle(.orange)
                    Text(NSLocalizedString("清理孤立数据", comment: ""))
                        .etFont(.footnote)
                    Spacer()
                    if orphanedDataCount.total > 0 {
                        Text(String(format: NSLocalizedString("%d 项", comment: ""), orphanedDataCount.total))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button(role: .destructive) {
                showClearCacheConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text(NSLocalizedString("清理所有缓存", comment: ""))
                        .etFont(.footnote)
                    Spacer()
                    Text(StorageUtility.formatSize(storageBreakdown.cacheSize))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(NSLocalizedString("清理工具", comment: ""))
        } footer: {
            Text(NSLocalizedString("孤立数据包括幽灵会话、孤立音频/图片、无效音频引用。", comment: ""))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshData() async {
        isLoading = true

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
            showCleanAllOrphansConfirmation = true
        } else {
            cleanupAlert = CleanupAlert(
                title: NSLocalizedString("无孤立数据", comment: ""),
                message: NSLocalizedString("当前没有需要清理的孤立数据。", comment: "")
            )
        }
    }

    private func performAllOrphanCleanup() {
        Task {
            let summary = await Task.detached(priority: .userInitiated) {
                StorageUtility.cleanupAllOrphans()
            }.value

            await MainActor.run {
                cleanupAlert = CleanupAlert(
                    title: NSLocalizedString("清理完成", comment: ""),
                    message: String(format: NSLocalizedString("已清理：%@", comment: ""), summary.description)
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
                    title: NSLocalizedString("清理完成", comment: ""),
                    message: String(format: NSLocalizedString("已删除 %d 个文件。", comment: ""), result.audioDeleted + result.imageDeleted)
                )
            }

            await refreshData()
        }
    }
}
