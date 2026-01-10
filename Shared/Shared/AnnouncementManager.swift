// ============================================================================
// AnnouncementManager.swift
// ============================================================================
// ETOS LLM Studio 公告通知管理器 (Shared)
//
// 功能特性:
// - 从远程服务器获取公告信息
// - 根据公告类型(info/warning/blocking)处理显示逻辑
// - 使用 AppStorage 持久化通知状态
// - 支持 iOS 和 watchOS
// ============================================================================

import Foundation
import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AnnouncementManager")

// MARK: - 数据模型

/// 公告类型
public enum AnnouncementType: String, Codable {
    case info = "info"           // 静默显示在设置里
    case warning = "warning"     // 首次显式通知
    case blocking = "blocking"   // 每次启动都显式通知
}

/// 公告数据模型
public struct Announcement: Codable, Identifiable {
    public let id: Int                  // 唯一标识，用日期+序号
    public let type: AnnouncementType   // 通知类型
    public let minBuild: String?        // 最低版本要求
    public let maxBuild: String?        // 最高版本要求
    public let title: String            // 标题
    public let body: String             // 正文内容
    
    enum CodingKeys: String, CodingKey {
        case id
        case type
        case minBuild = "min_build"
        case maxBuild = "max_build"
        case title
        case body
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(Int.self, forKey: .id)
        type = try container.decode(AnnouncementType.self, forKey: .type)
        minBuild = try container.decodeIfPresent(String.self, forKey: .minBuild)
        maxBuild = try container.decodeIfPresent(String.self, forKey: .maxBuild)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
    }
}

// MARK: - 公告管理器

@MainActor
public class AnnouncementManager: ObservableObject {
    
    // MARK: - 单例
    
    public static let shared = AnnouncementManager()
    
    // MARK: - Published 属性
    
    /// 当前公告（用于UI显示）
    @Published public var currentAnnouncement: Announcement?
    
    /// 是否应该显示弹窗通知
    @Published public var shouldShowAlert: Bool = false
    
    /// 是否正在加载
    @Published public var isLoading: Bool = false
    
    // MARK: - AppStorage 持久化
    
    /// 上次显示的通知ID
    @AppStorage("lastAnnouncementId") private var lastAnnouncementId: Int = 0
    
    /// 是否隐藏静默通知区域
    @AppStorage("hideAnnouncementSection") private var hideAnnouncementSection: Bool = false
    
    // MARK: - 私有属性
    
    private let announcementURL = URL(string: "https://notify.els.ericterminal.com/announcement.json")!
    private let timeoutInterval: TimeInterval = 10.0
    
    // MARK: - 计算属性
    
    /// 是否应该在设置中显示通知Section
    public var shouldShowInSettings: Bool {
        return currentAnnouncement != nil && !hideAnnouncementSection
    }
    
    // MARK: - 初始化
    
    private init() {
        logger.info("📢 AnnouncementManager initialized")
    }
    
    // MARK: - 公开方法
    
    /// 检查并加载公告
    /// 在App启动时调用
    public func checkAnnouncement() async {
        logger.info("📢 开始检查公告...")
        isLoading = true
        
        defer {
            isLoading = false
        }
        
        do {
            let announcement = try await fetchAnnouncement()
            await processAnnouncement(announcement)
        } catch {
            logger.error("📢 获取公告失败: \(error.localizedDescription)")
            // 网络失败时不修改已有的AppStorage设置
            // 也不显示任何通知
            currentAnnouncement = nil
        }
    }
    
    /// 用户点击"不再显示"后调用
    public func hideCurrentAnnouncement() {
        hideAnnouncementSection = true
        logger.info("📢 用户选择隐藏当前公告")
    }
    
    /// 关闭弹窗
    public func dismissAlert() {
        shouldShowAlert = false
    }
    
    // MARK: - 私有方法
    
    /// 从服务器获取公告
    private func fetchAnnouncement() async throws -> Announcement {
        logger.info("📢 正在从服务器获取公告...")
        
        var request = URLRequest(url: announcementURL)
        request.timeoutInterval = timeoutInterval
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AnnouncementError.invalidResponse
        }
        
        let decoder = JSONDecoder()
        let announcement = try decoder.decode(Announcement.self, from: data)
        
        logger.info("📢 成功获取公告: ID=\(announcement.id), Type=\(announcement.type.rawValue)")
        return announcement
    }
    
    /// 处理获取到的公告
    private func processAnnouncement(_ announcement: Announcement) async {
        // 检查版本兼容性
        guard isVersionCompatible(announcement) else {
            logger.info("📢 公告版本不兼容，跳过显示")
            currentAnnouncement = nil
            return
        }
        
        let isNewAnnouncement = announcement.id != lastAnnouncementId
        
        // 如果是新公告，重置隐藏状态
        if isNewAnnouncement {
            hideAnnouncementSection = false
            logger.info("📢 检测到新公告 (ID: \(announcement.id))，重置隐藏状态")
        }
        
        // 设置当前公告（用于静默显示）
        currentAnnouncement = announcement
        
        // 根据类型决定是否显示弹窗
        switch announcement.type {
        case .info:
            // info 类型只在设置中静默显示，不弹窗
            logger.info("📢 Info类型公告，静默显示")
            
        case .warning:
            // warning 类型仅在新公告时弹窗
            if isNewAnnouncement {
                shouldShowAlert = true
                logger.info("📢 Warning类型新公告，显示弹窗")
            } else {
                logger.info("📢 Warning类型旧公告，降级为静默显示")
            }
            
        case .blocking:
            // blocking 类型每次都弹窗
            shouldShowAlert = true
            logger.info("📢 Blocking类型公告，强制显示弹窗")
        }
        
        // 更新本地存储的ID（仅在成功获取公告后）
        lastAnnouncementId = announcement.id
        logger.info("📢 已更新本地公告ID为: \(announcement.id)")
    }
    
    /// 检查版本兼容性
    private func isVersionCompatible(_ announcement: Announcement) -> Bool {
        // 获取当前App的Build版本号
        guard let buildString = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let currentBuild = Int(buildString) else {
            logger.warning("📢 无法获取当前Build版本号")
            return true // 如果无法获取版本号，默认显示
        }
        
        // 检查最低版本要求
        if let minBuildString = announcement.minBuild,
           let minBuild = Int(minBuildString),
           currentBuild < minBuild {
            logger.info("📢 当前版本 \(currentBuild) 低于最低要求 \(minBuild)")
            return false
        }
        
        // 检查最高版本要求
        if let maxBuildString = announcement.maxBuild,
           let maxBuild = Int(maxBuildString),
           currentBuild > maxBuild {
            logger.info("📢 当前版本 \(currentBuild) 高于最高限制 \(maxBuild)")
            return false
        }
        
        return true
    }
}

// MARK: - 错误类型

public enum AnnouncementError: Error, LocalizedError {
    case invalidResponse
    case decodingFailed
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器响应无效"
        case .decodingFailed:
            return "数据解析失败"
        case .timeout:
            return "请求超时"
        }
    }
}
