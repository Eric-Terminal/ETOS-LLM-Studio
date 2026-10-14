import ETOSCore
import Foundation
import UniformTypeIdentifiers

struct MacComposerAttachment: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let image: ImageAttachment?
    let file: FileAttachment?

    init(data: Data, type: UTType, fileName: String) {
        id = UUID()
        self.fileName = fileName
        if type.conforms(to: .image) {
            image = ImageAttachment(id: id, data: data, mimeType: type.preferredMIMEType ?? "image/png", fileName: fileName)
            file = nil
        } else {
            image = nil
            file = FileAttachment(id: id, data: data, mimeType: type.preferredMIMEType ?? "application/octet-stream", fileName: fileName)
        }
    }
}
