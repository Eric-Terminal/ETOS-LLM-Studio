// ============================================================================
// AnnouncementDetailView.swift (iOS)
// ============================================================================
// ETOS LLM Studio iOS App 公告详情视图
//
// 功能特性:
// - 显示公告的完整内容
// - 提供"不再显示"选项
// ============================================================================

import SwiftUI
import Shared

/// 公告详情视图
struct AnnouncementDetailView: View {
    
    // MARK: - 属性
    
    let announcement: Announcement
    
    @ObservedObject var announcementManager: AnnouncementManager
    
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - 视图主体
    
    var body: some View {
        List {
            // MARK: - 公告内容部分
            Section {
                Text(announcement.body)
                    .font(.body)
                    .foregroundColor(.primary)
            } header: {
                announcementTypeLabel
            }
            
            // MARK: - 操作部分
            Section {
                Button(role: .destructive) {
                    announcementManager.hideCurrentAnnouncement()
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "eye.slash")
                        Text("不再显示此通知")
                    }
                }
            } footer: {
                Text("隐藏后，此通知将不会在设置中显示。如有新通知，将自动恢复显示。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(announcement.title)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - 子视图
    
    /// 公告类型标签
    @ViewBuilder
    private var announcementTypeLabel: some View {
        HStack(spacing: 4) {
            switch announcement.type {
            case .info:
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                Text("通知")
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("重要通知")
            case .blocking:
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundColor(.red)
                Text("紧急通知")
            @unknown default:
                Image(systemName: "bell.fill")
                    .foregroundColor(.gray)
                Text("通知")
            }
        }
        .font(.subheadline)
    }
}

// MARK: - 公告弹窗视图

/// 用于显示弹窗通知的视图
struct AnnouncementAlertView: View {
    
    let announcement: Announcement
    let onDismiss: () -> Void
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 图标
                    alertIcon
                        .font(.system(size: 60))
                        .padding(.top, 32)
                    
                    // 标题
                    Text(announcement.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)
                    
                    // 内容
                    Text(announcement.body)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    
                    Spacer(minLength: 32)
                    
                    // 确认按钮
                    Button(action: onDismiss) {
                        Text("我知道了")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(buttonTint)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .interactiveDismissDisabled(announcement.type == .blocking)
            .toolbar {
                if announcement.type != .blocking {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") {
                            onDismiss()
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 辅助属性
    
    @ViewBuilder
    private var alertIcon: some View {
        switch announcement.type {
        case .info:
            Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        case .blocking:
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundColor(.red)
        @unknown default:
            Image(systemName: "bell.fill")
                .foregroundColor(.gray)
        }
    }
    
    private var buttonTint: Color {
        switch announcement.type {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .blocking:
            return .red
        @unknown default:
            return .gray
        }
    }
}
