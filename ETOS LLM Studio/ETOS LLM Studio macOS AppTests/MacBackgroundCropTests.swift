import AppKit
import ETOSCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ETOS_LLM_Studio_macOS_App

struct MacBackgroundCropTests {
    @Test("原始比例不裁切，其他比例与缩放始终限制在原图内")
    func geometryPreservesAspectAndBounds() {
        let size = CGSize(width: 400, height: 200)
        #expect(MacBackgroundCropParameters().pixelRect(for: size) == CGRect(origin: .zero, size: size))
        for aspect in MacBackgroundCropAspect.allCases {
            for zoom in [1.0, 2.5, 6.0] {
                for position in [0.0, 0.5, 1.0] {
                    let crop = MacBackgroundCropParameters(aspect: aspect, zoom: zoom, horizontal: position, vertical: position)
                    let unit = crop.unitRect(for: size)
                    #expect(unit.minX >= 0 && unit.minY >= 0 && unit.maxX <= 1 && unit.maxY <= 1)
                    #expect(abs(unit.width * size.width / (unit.height * size.height) - aspect.ratio(original: size)) < 0.00001)
                    let pixels = crop.pixelRect(for: size)
                    #expect(CGRect(origin: .zero, size: size).contains(pixels))
                    #expect(pixels.width >= 1 && pixels.height >= 1)
                }
            }
        }
    }

    @Test("图片向右下拖动会查看左上区域，超出范围时保持靠边")
    func dragDirectionAndClamping() {
        let size = CGSize(width: 400, height: 200)
        let original = MacBackgroundCropParameters(zoom: 2)
        let moved = original.moved(by: CGSize(width: 50, height: 25), displayedImageSize: size, sourceSize: size)
        #expect(moved.horizontal == 0.25 && moved.vertical == 0.25)
        let edge = original.moved(by: CGSize(width: -4000, height: 2000), displayedImageSize: size, sourceSize: size)
        #expect(edge.horizontal == 1 && edge.vertical == 0)
        let full = MacBackgroundCropParameters()
        #expect(full.moved(by: CGSize(width: 40, height: 20), displayedImageSize: size, sourceSize: size) == full)
    }

    @Test("裁切保存使用完整原图像素，独立 PNG 保留透明度且不覆盖来源")
    func cropUsesOriginalResolutionAndPreservesSource() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("original.png")
        let bytes = try image(width: 2400, height: 1200)
        try bytes.write(to: url)
        let library = MacBackgroundLibrary(directory: root)
        let file = try #require(try await library.load().files.first)
        let prepared = try await library.prepareCrop(file)
        #expect(prepared.pixelSize == CGSize(width: 2400, height: 1200))
        #expect(prepared.preview.representations.first?.pixelsWide == 1600)
        let output = try await library.saveCrop(file, parameters: .init(aspect: .square, zoom: 2))
        let source = try #require(CGImageSourceCreateWithURL(output.url as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 600 && decoded.height == 600)
        #expect(decoded.alphaInfo != .none && decoded.alphaInfo != .noneSkipFirst && decoded.alphaInfo != .noneSkipLast)
        #expect(output.id != file.id && output.id.hasSuffix(".png"))
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try await library.load().files.count == 2)
    }

    @Test("带 EXIF 方向的照片先归一化方向，再计算预览与输出裁切尺寸")
    func orientedImageUsesUprightPixels() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try image(width: 600, height: 300, orientation: 6).write(to: root.appendingPathComponent("rotated.jpg"))
        let library = MacBackgroundLibrary(directory: root)
        let file = try #require(try await library.load().files.first)
        let preview = try await library.prepareCrop(file)
        #expect(preview.pixelSize == CGSize(width: 300, height: 600))
        let output = try await library.saveCrop(file, parameters: .init())
        let source = try #require(CGImageSourceCreateWithURL(output.url as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 300 && decoded.height == 600)
    }

    @Test("准备后来源文件被替换时，旧草稿不能裁切新文件")
    func changedSourceRejectsDraft() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("image.png")
        try image(width: 40, height: 20).write(to: url)
        let library = MacBackgroundLibrary(directory: root)
        let file = try #require(try await library.load().files.first)
        _ = try await library.prepareCrop(file)
        let replacement = try image(width: 20, height: 40)
        try replacement.write(to: url, options: .atomic)
        await #expect(throws: MacBackgroundLibrary.LibraryError.self) { try await library.saveCrop(file, parameters: .init()) }
        #expect(try await library.load().files.count == 1)
        #expect(try Data(contentsOf: url) == replacement)
    }

    @Test("非有限或越界的草稿参数被拒绝，不发布新图片")
    func invalidCropIsRejected() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try image(width: 40, height: 20).write(to: root.appendingPathComponent("image.png"))
        let library = MacBackgroundLibrary(directory: root)
        let file = try #require(try await library.load().files.first)
        for parameters in [MacBackgroundCropParameters(zoom: .nan), .init(zoom: 0), .init(zoom: 7),
                           .init(horizontal: .infinity), .init(horizontal: -0.1), .init(vertical: 1.1)] {
            await #expect(throws: MacBackgroundLibrary.LibraryError.self) { try await library.saveCrop(file, parameters: parameters) }
        }
        #expect(try await library.load().files.count == 1)
    }

    @Test("取消的裁切不发布新图片，来源仍然可用")
    func cancelledCropDoesNotPublish() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try image(width: 40, height: 20).write(to: root.appendingPathComponent("image.png"))
        let library = MacBackgroundLibrary(directory: root)
        let file = try #require(try await library.load().files.first)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream { }
            return try await library.saveCrop(file, parameters: .init(aspect: .square))
        }
        task.cancel(); continuation.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await library.load().identifiers == [file.id])
    }

    @Test("重置只恢复位置与缩放，保留草稿选定的比例")
    @MainActor func resetPreservesAspect() {
        let file = MacBackgroundFile(id: "image.png", url: URL(fileURLWithPath: "/test/image.png"), isVideo: false, size: 0, modifiedAt: nil, resourceID: "test")
        let draft = MacBackgroundCropDraft(file: file, sourceEpoch: UUID())
        draft.parameters = .init(aspect: .phone, zoom: 5, horizontal: 1, vertical: 0)
        draft.reset()
        #expect(draft.parameters == .init(aspect: .phone))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func image(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let type = orientation == nil ? UTType.png : UTType.jpeg
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
