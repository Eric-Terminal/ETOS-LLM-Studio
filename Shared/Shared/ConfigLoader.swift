// ============================================================================
// ConfigLoader.swift
// ============================================================================
// ETOS LLM Studio - Provider 配置加载与管理
//
// 功能特性:
// - 管理用户专属的 `Providers` 目录。
// - App首次启动时，自动从 Bundle 的 `Providers_template` 目录中拷贝模板配置。
// - 提供加载、保存、删除单个提供商配置文件的静态方法。
// ============================================================================

import Foundation
import os.log

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ConfigLoader")

public struct ConfigLoader {
    
    // MARK: - 目录管理

    /// 获取用户专属的根目录 URL
    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    /// 获取存放提供商配置的目录 URL
    private static var providersDirectory: URL {
        documentsDirectory.appendingPathComponent("Providers")
    }

    /// 检查并初始化提供商配置目录。
    /// 如果 `Providers` 目录不存在，则创建它。
    public static func setupInitialProviderConfigs() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: providersDirectory.path) else {
            // 目录已存在，无需任何操作。
            return
        }
        
        logger.warning("⚠️ 用户提供商配置目录不存在。正在创建...")
        
        do {
            // 1. 创建 Providers 目录
            try fileManager.createDirectory(at: providersDirectory, withIntermediateDirectories: true, attributes: nil)
            logger.info("  - 成功创建目录: \(providersDirectory.path)")
        } catch {
            logger.error("❌ 初始化提供商配置目录失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 增删改查操作

    /// 从 `Providers` 目录加载所有提供商的配置。
    /// - Returns: 一个包含所有已加载 `Provider` 对象的数组。
    public static func loadProviders() -> [Provider] {
        logger.info("🔄 正在从 \(providersDirectory.path) 加载所有提供商...")
        let fileManager = FileManager.default
        var providers: [Provider] = []

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: providersDirectory, includingPropertiesForKeys: nil)
            for url in fileURLs.filter({ $0.pathExtension == "json" }) {
                do {
                    let data = try Data(contentsOf: url)
                    let provider = try JSONDecoder().decode(Provider.self, from: data)
                    providers.append(provider)
                    logger.info("  - ✅ 成功加载: \(url.lastPathComponent)")
                } catch {
                    logger.error("  - ❌ 解析文件失败 \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("❌ 无法读取 Providers 目录: \(error.localizedDescription)")
        }
        
        logger.info("总共加载了 \(providers.count) 个提供商。")
        return providers
    }
    
    /// 将单个提供商的配置保存（或更新）到其对应的 JSON 文件。
    /// - Parameter provider: 需要保存的 `Provider` 对象。
    public static func saveProvider(_ provider: Provider) {
        // 使用 provider 的 ID 作为文件名以确保唯一性
        let fileURL = providersDirectory.appendingPathComponent("\(provider.id.uuidString).json")
        logger.info("💾 正在保存提供商 \(provider.name) 到 \(fileURL.path)")
        
        do {
            // 使用“先删再写”模式，确保能覆盖文件
            try? FileManager.default.removeItem(at: fileURL)
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(provider)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("  - ✅ 保存成功。")
        } catch {
            logger.error("  - ❌ 保存失败: \(error.localizedDescription)")
        }
    }
    
    /// 删除指定提供商的配置文件。
    /// - Parameter provider: 需要删除的 `Provider` 对象。
    public static func deleteProvider(_ provider: Provider) {
        let fileURL = providersDirectory.appendingPathComponent("\(provider.id.uuidString).json")
        logger.info("🗑️ 正在删除提供商 \(provider.name) 的配置文件: \(fileURL.path)")

        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("  - ✅ 删除成功。")
        } catch {
            logger.error("  - ❌ 删除失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 背景图片管理

    /// 获取存放背景图片的目录 URL
    public static func getBackgroundsDirectory() -> URL {
        documentsDirectory.appendingPathComponent("Backgrounds")
    }

    /// 检查并初始化背景图片目录。
    /// 如果 `Backgrounds` 目录不存在，则创建它。
    public static func setupBackgroundsDirectory() {
        let backgroundsDirectory = getBackgroundsDirectory()
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: backgroundsDirectory.path) else {
            return
        }
        
        logger.warning("⚠️ 用户背景图片目录不存在。正在创建...")
        
        do {
            try fileManager.createDirectory(at: backgroundsDirectory, withIntermediateDirectories: true, attributes: nil)
            logger.info("  - 成功创建目录: \(backgroundsDirectory.path)")
        } catch {
            logger.error("❌ 初始化背景图片目录失败: \(error.localizedDescription)")
        }
    }

    /// 从 `Backgrounds` 目录加载所有图片的文件名。
    /// - Returns: 一个包含所有图片文件名的数组。
    public static func loadBackgroundImages() -> [String] {
        logger.info("🔄 正在从 \(getBackgroundsDirectory().path) 加载所有背景图片...")
        let fileManager = FileManager.default
        var imageNames: [String] = []

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: getBackgroundsDirectory(), includingPropertiesForKeys: nil)
            // 支持常见的图片格式
            let supportedExtensions = ["png", "jpg", "jpeg", "webp"]
            for url in fileURLs {
                if supportedExtensions.contains(url.pathExtension.lowercased()) {
                    imageNames.append(url.lastPathComponent)
                }
            }
        } catch {
            logger.error("❌ 无法读取 Backgrounds 目录: \(error.localizedDescription)")
        }
        
        logger.info("总共加载了 \(imageNames.count) 个背景图片。")
        return imageNames
    }
}