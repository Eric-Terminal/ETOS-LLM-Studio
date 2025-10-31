import Foundation

public struct AudioAttachment {
    public let data: Data
    public let mimeType: String
    public let format: String
    public let fileName: String
    
    public init(data: Data, mimeType: String, format: String, fileName: String) {
        self.data = data
        self.mimeType = mimeType
        self.format = format
        self.fileName = fileName
    }
}
