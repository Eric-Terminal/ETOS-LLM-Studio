// ============================================================================
// PersistenceMediaStorage.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Persistence 的音频、图片、文件与字体文件目录管理和文件读写。
// ============================================================================

import Foundation
import os.log

private let mediaStorageLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "PersistenceMediaStorage")

extension Persistence {
    /// 获取用于存储音频文件的目录URL
    /// - Returns: 音频存储目录的URL路径
    public static func getAudioDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let audioDirectory = paths[0].appendingPathComponent("AudioFiles")
        if !FileManager.default.fileExists(atPath: audioDirectory.path) {
            mediaStorageLogger.info("Audio directory does not exist, creating: \(audioDirectory.path)")
            try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        }
        return audioDirectory
    }

    /// 保存音频数据到文件
    /// - Parameters:
    ///   - data: 音频数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveAudio(_ data: Data, fileName: String) -> URL? {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        mediaStorageLogger.info("Saving audio file: \(fileName)")

        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            mediaStorageLogger.info("Audio file saved successfully: \(fileName)")
            return fileURL
        } catch {
            mediaStorageLogger.error("Failed to save audio file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// 加载音频数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 音频数据，如果文件不存在则返回nil
    public static func loadAudio(fileName: String) -> Data? {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        mediaStorageLogger.info("Loading audio file: \(fileName)")

        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            mediaStorageLogger.info("Audio file loaded successfully: \(fileName)")
            return data
        } catch {
            mediaStorageLogger.warning("Failed to load audio file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// 检查音频文件是否存在
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件是否存在
    public static func audioFileExists(fileName: String) -> Bool {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// 删除指定的音频文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteAudio(fileName: String) {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        mediaStorageLogger.info("Deleting audio file: \(fileName)")

        do {
            try FileManager.default.removeItem(at: fileURL)
            mediaStorageLogger.info("Audio file deleted successfully: \(fileName)")
        } catch {
            mediaStorageLogger.warning("Failed to delete audio file \(fileName): \(error.localizedDescription)")
        }
    }

    /// 删除会话相关的所有音频文件
    /// - Parameters:
    ///   - messages: 会话中的消息列表
    public static func deleteAudioFiles(for messages: [ChatMessage]) {
        let audioFileNames = messages.compactMap { $0.audioFileName }
        for fileName in audioFileNames {
            deleteAudio(fileName: fileName)
        }
        if !audioFileNames.isEmpty {
            mediaStorageLogger.info("Deleted \(audioFileNames.count) audio files for session.")
        }
    }

    /// 获取所有音频文件
    /// - Returns: 音频文件名数组
    public static func getAllAudioFileNames() -> [String] {
        let directory = getAudioDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            mediaStorageLogger.warning("Failed to list audio files: \(error.localizedDescription)")
            return []
        }
    }

    /// 获取用于存储图片文件的目录URL
    /// - Returns: 图片存储目录的URL路径
    public static func getImageDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let imageDirectory = paths[0].appendingPathComponent("ImageFiles")
        if !FileManager.default.fileExists(atPath: imageDirectory.path) {
            mediaStorageLogger.info("Image directory does not exist, creating: \(imageDirectory.path)")
            try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        }
        return imageDirectory
    }

    /// 保存图片数据到文件
    /// - Parameters:
    ///   - data: 图片数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveImage(_ data: Data, fileName: String) -> URL? {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        mediaStorageLogger.info("Saving image file: \(fileName)")

        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            mediaStorageLogger.info("Image file saved successfully: \(fileName)")
            return fileURL
        } catch {
            mediaStorageLogger.error("Failed to save image file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// 加载图片数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 图片数据，如果文件不存在则返回nil
    public static func loadImage(fileName: String) -> Data? {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)

        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            return data
        } catch {
            mediaStorageLogger.warning("Failed to load image file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// 检查图片文件是否存在
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件是否存在
    public static func imageFileExists(fileName: String) -> Bool {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// 删除指定的图片文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteImage(fileName: String) {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        mediaStorageLogger.info("Deleting image file: \(fileName)")

        do {
            try FileManager.default.removeItem(at: fileURL)
            mediaStorageLogger.info("Image file deleted successfully: \(fileName)")
        } catch {
            mediaStorageLogger.warning("Failed to delete image file \(fileName): \(error.localizedDescription)")
        }
    }

    /// 删除会话相关的所有图片文件
    /// - Parameters:
    ///   - messages: 会话中的消息列表
    public static func deleteImageFiles(for messages: [ChatMessage]) {
        let imageFileNames = messages.flatMap { $0.imageFileNames ?? [] }
        for fileName in imageFileNames {
            deleteImage(fileName: fileName)
        }
        if !imageFileNames.isEmpty {
            mediaStorageLogger.info("Deleted \(imageFileNames.count) image files for session.")
        }
    }

    /// 获取所有图片文件名
    /// - Returns: 图片文件名数组
    public static func getAllImageFileNames() -> [String] {
        let directory = getImageDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            mediaStorageLogger.warning("Failed to list image files: \(error.localizedDescription)")
            return []
        }
    }

    /// 获取用于存储文件附件的目录URL
    /// - Returns: 文件附件存储目录的URL路径
    public static func getFileDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let fileDirectory = paths[0].appendingPathComponent("FileAttachments")
        if !FileManager.default.fileExists(atPath: fileDirectory.path) {
            mediaStorageLogger.info("File attachment directory does not exist, creating: \(fileDirectory.path)")
            try? FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
        }
        return fileDirectory
    }

    /// 保存文件数据到文件
    /// - Parameters:
    ///   - data: 文件数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveFile(_ data: Data, fileName: String) -> URL? {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        mediaStorageLogger.info("Saving file attachment: \(fileName)")

        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            mediaStorageLogger.info("File attachment saved successfully: \(fileName)")
            return fileURL
        } catch {
            mediaStorageLogger.error("Failed to save file attachment \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// 加载文件数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件数据，如果文件不存在则返回nil
    public static func loadFile(fileName: String) -> Data? {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        mediaStorageLogger.info("Loading file attachment: \(fileName)")

        do {
            let data = try Data(contentsOf: fileURL)
            mediaStorageLogger.info("File attachment loaded successfully: \(fileName)")
            return data
        } catch {
            mediaStorageLogger.warning("Failed to load file attachment \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// 检查文件是否存在
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件是否存在
    public static func fileExists(fileName: String) -> Bool {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// 删除指定的文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteFile(fileName: String) {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        mediaStorageLogger.info("Deleting file attachment: \(fileName)")

        do {
            try FileManager.default.removeItem(at: fileURL)
            mediaStorageLogger.info("File attachment deleted successfully: \(fileName)")
        } catch {
            mediaStorageLogger.warning("Failed to delete file attachment \(fileName): \(error.localizedDescription)")
        }
    }

    /// 删除会话相关的所有文件附件
    /// - Parameters:
    ///   - messages: 会话中的消息列表
    public static func deleteFileFiles(for messages: [ChatMessage]) {
        let fileNames = messages.flatMap { $0.fileFileNames ?? [] }
        for fileName in fileNames {
            deleteFile(fileName: fileName)
        }
        if !fileNames.isEmpty {
            mediaStorageLogger.info("Deleted \(fileNames.count) file attachments for session.")
        }
    }

    /// 获取所有文件附件名
    /// - Returns: 文件附件名数组
    public static func getAllFileNames() -> [String] {
        let directory = getFileDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            mediaStorageLogger.warning("Failed to list file attachments: \(error.localizedDescription)")
            return []
        }
    }

    /// 获取用于存储字体文件的目录URL
    /// - Returns: 字体存储目录的URL路径
    public static func getFontDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let fontDirectory = paths[0].appendingPathComponent("FontFiles")
        if !FileManager.default.fileExists(atPath: fontDirectory.path) {
            mediaStorageLogger.info("Font directory does not exist, creating: \(fontDirectory.path)")
            try? FileManager.default.createDirectory(at: fontDirectory, withIntermediateDirectories: true)
        }
        return fontDirectory
    }

    /// 保存字体数据到文件
    /// - Parameters:
    ///   - data: 字体数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveFont(_ data: Data, fileName: String) -> URL? {
        let fileURL = getFontDirectory().appendingPathComponent(fileName)
        mediaStorageLogger.info("Saving font file: \(fileName)")

        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            mediaStorageLogger.info("Font file saved successfully: \(fileName)")
            return fileURL
        } catch {
            mediaStorageLogger.error("Failed to save font file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// 加载字体数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 字体数据，如果文件不存在则返回nil
    public static func loadFont(fileName: String) -> Data? {
        let fileURL = getFontDirectory().appendingPathComponent(fileName)

        do {
            return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            mediaStorageLogger.warning("Failed to load font file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// 删除指定字体文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteFont(fileName: String) {
        let fileURL = getFontDirectory().appendingPathComponent(fileName)
        mediaStorageLogger.info("Deleting font file: \(fileName)")

        do {
            try FileManager.default.removeItem(at: fileURL)
            mediaStorageLogger.info("Font file deleted successfully: \(fileName)")
        } catch {
            mediaStorageLogger.warning("Failed to delete font file \(fileName): \(error.localizedDescription)")
        }
    }

    /// 获取所有字体文件名
    /// - Returns: 字体文件名数组
    public static func getAllFontFileNames() -> [String] {
        let directory = getFontDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            mediaStorageLogger.warning("Failed to list font files: \(error.localizedDescription)")
            return []
        }
    }
}
