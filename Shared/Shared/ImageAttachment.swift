import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 图片附件，用于发送给支持视觉的模型
public struct ImageAttachment: Identifiable {
    public let id: UUID
    public let data: Data
    public let mimeType: String
    public let fileName: String
    
    /// 缩略图数据（用于预览）
    public let thumbnailData: Data?
    
    public init(id: UUID = UUID(), data: Data, mimeType: String, fileName: String, thumbnailData: Data? = nil) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
        self.thumbnailData = thumbnailData
    }
    
    /// Base64 编码的数据 URL
    public var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
    
#if canImport(UIKit) && !os(watchOS)
    /// 从 UIImage 创建附件 (仅 iOS)
    public static func from(image: UIImage, compressionQuality: CGFloat = 0.8) -> ImageAttachment? {
        guard let data = image.jpegData(compressionQuality: compressionQuality) else {
            return nil
        }
        
        // 生成缩略图
        let thumbnailSize = CGSize(width: 100, height: 100)
        let thumbnailData: Data? = {
            let renderer = UIGraphicsImageRenderer(size: thumbnailSize)
            let thumbnail = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
            }
            return thumbnail.jpegData(compressionQuality: 0.6)
        }()
        
        return ImageAttachment(
            data: data,
            mimeType: "image/jpeg",
            fileName: "\(UUID().uuidString).jpg",
            thumbnailData: thumbnailData
        )
    }
    
    /// 获取缩略图 UIImage
    public var thumbnailImage: UIImage? {
        guard let thumbnailData else { return nil }
        return UIImage(data: thumbnailData)
    }
    
    /// 获取完整图片 UIImage
    public var fullImage: UIImage? {
        UIImage(data: data)
    }
#endif
}

/// 通用文件附件，用于发送给支持文件输入的模型
public struct FileAttachment: Identifiable {
    public let id: UUID
    public let data: Data
    public let mimeType: String
    public let fileName: String
    
    public init(id: UUID = UUID(), data: Data, mimeType: String, fileName: String) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
    }
}
