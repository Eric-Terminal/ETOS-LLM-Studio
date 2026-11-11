import Foundation
import Testing
@testable import ETOSCore

@Suite("本地网页地址与资源边界")
struct BrowserLocalResourceTests {
    @Test("工作区与沙箱地址保留查询和锚点，目录默认打开首页")
    func localAddresses() throws {
        let url = try #require(URL(string: "etos://workspace/moments/%E4%B8%AD%E6%96%87%20page.html?mode=dark#note"))
        #expect(try BrowserLocalResource.validatedNavigationURL(url) == url)
        #expect(try BrowserLocalResource.pathComponents(url) == ["moments", "中文 page.html"])
        #expect(try BrowserLocalResource.pathComponents(URL(string: "etos://sandbox/moments/")!) == ["moments", "index.html"])
        #expect(try BrowserLocalResource.pathComponents(URL(string: "etos://workspace/")!) == ["index.html"])
    }

    @Test("拒绝未知空间、凭据、端口和编码后的路径穿越")
    func rejectsInvalidAddresses() throws {
        for value in [
            "etos://other/index.html", "etos://user@workspace/index.html", "etos://workspace:80/index.html",
            "etos://workspace/../private.html", "etos://workspace/%2e%2e/private.html",
            "etos://workspace/a%2fb.html", "etos://workspace/a%5cb.html", "etos://workspace/a%00.html",
            "file:///tmp/index.html", "javascript:alert(1)", "https://"
        ] {
            let url = try #require(URL(string: value))
            #expect(throws: BrowserAgentError.self) { try BrowserLocalResource.validatedNavigationURL(url) }
        }
        #expect(BrowserLocalResource.navigationHost(URL(string: "etos://workspace/index.html")) != BrowserLocalResource.navigationHost(URL(string: "https://workspace/index.html")))
    }

    @Test("HTML 及相对资源读取正确 MIME，更新文件后读取新内容")
    func resourcesAndReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("moments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = URL(string: "etos://workspace/moments/index.html?version=1#title")!
        let entries = [
            ("index.html", "<h1>本地页面</h1>", "text/html"),
            ("main.css", "body { color: red; }", "text/css"),
            ("main.js", "window.ready = true;", "text/javascript"),
            ("data.json", "{\"ready\":true}", "application/json"),
            ("图片.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"/>", "image/svg+xml")
        ]
        for (name, content, mime) in entries {
            try Data(content.utf8).write(to: directory.appendingPathComponent(name))
            let url = try #require(URL(string: name, relativeTo: page)?.absoluteURL)
            let resource = try BrowserLocalResource.read(url, rootDirectory: root)
            #expect(resource.data == Data(content.utf8))
            #expect(resource.mimeType == mime)
        }
        try Data("<h1>已更新</h1>".utf8).write(to: directory.appendingPathComponent("index.html"))
        #expect(try BrowserLocalResource.read(page, rootDirectory: root).data == Data("<h1>已更新</h1>".utf8))
    }

    @Test("拒绝目录和叶子符号链接、缺失文件、不支持的类型及超大资源")
    func rejectsUnsafeFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("private.html")
        try Data("private".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.html"), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory.html"), withIntermediateDirectories: true)
        for name in ["linked.html", "linked/private.html", "missing.html", "private.sqlite", "directory.html"] {
            let url = URL(string: "etos://sandbox/\(name)")!
            #expect(throws: BrowserAgentError.self) { try BrowserLocalResource.read(url, rootDirectory: root) }
        }
        let oversized = root.appendingPathComponent("large.html")
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(BrowserLocalResource.maximumBytes + 1))
        try handle.close()
        #expect(throws: BrowserAgentError.self) {
            try BrowserLocalResource.read(URL(string: "etos://sandbox/large.html")!, rootDirectory: root)
        }
    }

    @Test("远程页面及不同本地空间不能跨源读取资源")
    func rejectsCrossOriginRequests() async throws {
        let reader = BrowserLocalResourceReader()
        for origin in ["https://example.com", "https://sandbox/index.html", "etos://workspace/index.html"] {
            var request = URLRequest(url: URL(string: "etos://sandbox/private.json")!)
            request.mainDocumentURL = URL(string: origin)
            await #expect(throws: URLError.self) { try await reader.read(request, sessionID: UUID()) }
        }
        var request = URLRequest(url: URL(string: "etos://sandbox/index.html")!)
        request.httpMethod = "POST"
        await #expect(throws: URLError.self) { try await reader.read(request, sessionID: UUID()) }
    }

    @Test("向导明确说明两种目录、资源限制及手表委托的设备边界")
    func guideDocumentsLocalPages() async throws {
        let document = try #require(await GuideKnowledgeService().document(id: "browser-agent"))
        for text in ["etos://workspace/moments/index.html", "etos://sandbox/moments/index.html", "16 MB", "不会自动复制手表文件"] {
            #expect(document.content.contains(text))
        }
    }
}
