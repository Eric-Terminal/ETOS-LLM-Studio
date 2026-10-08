import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacBackgroundTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!

    @Test("空目录读取不创建媒体或改动数据")
    func emptyLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = MacBackgroundLibrary(directory: root)
        #expect(try await library.load().files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("目录忽略隐藏文件、目录、符号链接及不支持的扩展名")
    func catalogFiltersUnsafeEntries() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try png.write(to: root.appendingPathComponent("image.png"))
        try png.write(to: root.appendingPathComponent(".hidden.png"))
        try png.write(to: root.appendingPathComponent("ignored.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.jpg"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.png"), withDestinationURL: root.appendingPathComponent("image.png"))
        let catalog = try await MacBackgroundLibrary(directory: root).load()
        #expect(catalog.identifiers == ["image.png"])
        #expect(catalog.byID["image.png"]?.isVideo == false)
        #expect(catalog.guideValue == .array([.string("image.png")]))
    }

    @Test("导入生成兼容相对文件名并保留原文件字节，同名源文件互不覆盖")
    func importPreservesBytes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("original.png"), destination = root.appendingPathComponent("Backgrounds")
        try png.write(to: input)
        let library = MacBackgroundLibrary(directory: destination)
        let first = try await library.importFile(input)
        let second = try await library.importFile(input)
        #expect(first.id.hasPrefix("background-") && first.id.hasSuffix(".png"))
        #expect(first.id != second.id)
        #expect(try Data(contentsOf: first.url) == png)
        #expect(try Data(contentsOf: input) == png)
        #expect(try await library.load().files.count == 2)
        try await library.delete(first)
        #expect(try await library.load().identifiers == [second.id])
    }

    @Test("无效图片导入失败且不在同步目录留下暂存文件")
    func malformedMediaLeavesNoPublishedFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("broken.jpg"), destination = root.appendingPathComponent("Backgrounds")
        try Data("不是图片".utf8).write(to: input)
        let library = MacBackgroundLibrary(directory: destination)
        await #expect(throws: MacBackgroundLibrary.LibraryError.self) { try await library.importFile(input) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test("导入不复制符号链接，删除也拒绝目录外目标")
    func fileOperationsStayWithinSelectedFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("original.png"), alias = root.appendingPathComponent("alias.png")
        try png.write(to: input)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        let library = MacBackgroundLibrary(directory: root.appendingPathComponent("Backgrounds"))
        await #expect(throws: MacBackgroundLibrary.LibraryError.self) { try await library.importFile(alias) }
        let foreign = try #require(try await MacBackgroundLibrary(directory: root).load().byID["original.png"])
        await #expect(throws: MacBackgroundLibrary.LibraryError.self) { try await library.delete(foreign) }
        #expect(try Data(contentsOf: input) == png)
    }

    @Test("文件已被替换时旧删除确认不能删除新内容")
    func staleDeletionIsRejected() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("image.png")
        try png.write(to: url)
        let library = MacBackgroundLibrary(directory: root)
        let original = try #require(try await library.load().files.first)
        let changed = png + Data([0])
        try changed.write(to: url, options: .atomic)
        await #expect(throws: MacBackgroundLibrary.LibraryError.self) { try await library.delete(original) }
        #expect(try Data(contentsOf: url) == changed)
    }

    @Test("取消的导入不会发布媒体文件")
    func cancelledImportDoesNotPublish() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.png")
        try png.write(to: input)
        let library = MacBackgroundLibrary(directory: root.appendingPathComponent("Backgrounds"))
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream { }
            return try await library.importFile(input)
        }
        task.cancel(); continuation.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await library.load().files.isEmpty)
    }

    @Test("启动轮换避开当前背景，零或单一候选不重复选择")
    func rotationUsesAnotherExistingFile() {
        func file(_ id: String) -> MacBackgroundFile {
            .init(id: id, url: URL(fileURLWithPath: "/test/\(id)"), isVideo: false, size: 0, modifiedAt: nil, resourceID: id)
        }
        let files = [file("a.png"), file("b.jpg"), file("c.webp")]
        let catalog = MacBackgroundCatalog(files)
        for file in files {
            let selected = catalog.nextRotatedID(excluding: file.id)
            #expect(selected != nil && selected != file.id)
            #expect(selected.map { catalog.byID[$0] != nil } == true)
        }
        #expect(MacBackgroundCatalog([]).nextRotatedID(excluding: "") == nil)
        #expect(MacBackgroundCatalog([files[0]]).nextRotatedID(excluding: "a.png") == nil)
    }

    @Test("视频后台暂停优先于隐藏继续，关闭背景总开关始终停止")
    func playbackPolicyRespectsVisibilityAndApplication() {
        #expect(MacBackgroundPlaybackPolicy.shouldPlay(enabled: true, visible: true, appActive: true, continueWhenHidden: false))
        #expect(!MacBackgroundPlaybackPolicy.shouldPlay(enabled: true, visible: false, appActive: true, continueWhenHidden: false))
        #expect(MacBackgroundPlaybackPolicy.shouldPlay(enabled: true, visible: false, appActive: true, continueWhenHidden: true))
        #expect(!MacBackgroundPlaybackPolicy.shouldPlay(enabled: true, visible: true, appActive: false, continueWhenHidden: true))
        #expect(!MacBackgroundPlaybackPolicy.shouldPlay(enabled: false, visible: true, appActive: true, continueWhenHidden: true))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-background-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
