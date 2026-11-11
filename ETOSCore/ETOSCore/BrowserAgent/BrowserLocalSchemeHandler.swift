import Foundation
#if os(watchOS)
import ObjectiveC
import CoreGraphics
#elseif canImport(WebKit)
import WebKit
#endif

/// WebKit 的回调留在主执行器，文件读取交给独立 actor；停止后绝不回调已失效的任务。
@MainActor
final class BrowserLocalSchemeHandler: NSObject {
    private let sessionID: UUID
    private let reader = BrowserLocalResourceReader()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(sessionID: UUID) { self.sessionID = sessionID; super.init() }

    private func start(
        id: ObjectIdentifier,
        request: URLRequest,
        response: @escaping (URLResponse) -> Void,
        data: @escaping (Data) -> Void,
        finish: @escaping () -> Void,
        fail: @escaping (Error) -> Void
    ) {
        let reader = reader, sessionID = sessionID
        tasks[id] = Task { [weak self] in
            do {
                let resource = try await reader.read(request, sessionID: sessionID)
                guard let self, !Task.isCancelled, tasks[id] != nil, let url = request.url else { return }
                // 禁用缓存，让文件工具更新页面后直接重载即可看到新内容。
                let contentType = resource.mimeType.hasPrefix("text/") || resource.mimeType == "application/json"
                    ? resource.mimeType + "; charset=utf-8" : resource.mimeType
                let headers = [
                    "Content-Type": contentType,
                    "Content-Length": String(resource.data.count),
                    "Cache-Control": "no-store",
                    "X-Content-Type-Options": "nosniff"
                ]
                response(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
                guard tasks[id] != nil else { return }
                if request.httpMethod != "HEAD" { data(resource.data) }
                guard tasks.removeValue(forKey: id) != nil else { return }
                finish()
            } catch {
                guard let self, !Task.isCancelled, tasks.removeValue(forKey: id) != nil else { return }
                fail(error)
            }
        }
    }

    private func stop(id: ObjectIdentifier) { tasks.removeValue(forKey: id)?.cancel() }
}

#if canImport(WebKit) && !os(watchOS)
extension BrowserLocalSchemeHandler: WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        var request = urlSchemeTask.request
        if request.mainDocumentURL == nil { request.mainDocumentURL = webView.url }
        start(
            id: ObjectIdentifier(urlSchemeTask), request: request,
            response: { urlSchemeTask.didReceive($0) }, data: { urlSchemeTask.didReceive($0) },
            finish: { urlSchemeTask.didFinish() }, fail: { urlSchemeTask.didFailWithError($0) }
        )
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stop(id: ObjectIdentifier(urlSchemeTask))
    }
}
#elseif os(watchOS)
extension BrowserLocalSchemeHandler {
    // watchOS 未公开 WebKit Swift 类型，沿用现有运行时桥接并逐项探测能力。
    @objc(webView:startURLSchemeTask:)
    func startRuntimeTask(_ webView: NSObject, task: NSObject) {
        guard var request = task.value(forKey: "request") as? URLRequest else { return }
        if request.mainDocumentURL == nil { request.mainDocumentURL = webView.value(forKey: "URL") as? URL }
        start(
            id: ObjectIdentifier(task), request: request,
            response: { _ = task.perform(NSSelectorFromString("didReceiveResponse:"), with: $0) },
            data: { _ = task.perform(NSSelectorFromString("didReceiveData:"), with: $0 as NSData) },
            finish: { _ = task.perform(NSSelectorFromString("didFinish")) },
            fail: { _ = task.perform(NSSelectorFromString("didFailWithError:"), with: $0 as NSError) }
        )
    }

    @objc(webView:stopURLSchemeTask:)
    func stopRuntimeTask(_ webView: NSObject, task: NSObject) { stop(id: ObjectIdentifier(task)) }

    static func makeRuntimeWebView(webViewClass: NSObject.Type, sessionID: UUID) -> NSObject {
        let register = NSSelectorFromString("setURLSchemeHandler:forURLScheme:")
        let initialize = NSSelectorFromString("initWithFrame:configuration:")
        guard let configurationClass = NSClassFromString("WKWebViewConfiguration") as? NSObject.Type,
              let handlerProtocol = NSProtocolFromString("WKURLSchemeHandler"),
              let allocateMethod = class_getClassMethod(webViewClass, NSSelectorFromString("alloc")),
              let initializeMethod = class_getInstanceMethod(webViewClass, initialize) else {
            // 旧运行时缺少本地协议接口时，仍保留原有的普通网页浏览能力。
            return webViewClass.init()
        }
        let configuration = configurationClass.init()
        guard configuration.responds(to: register) else { return webViewClass.init() }
        class_addProtocol(BrowserLocalSchemeHandler.self, handlerProtocol)
        let handler = BrowserLocalSchemeHandler(sessionID: sessionID)
        configuration.perform(register, with: handler, with: BrowserLocalResource.scheme as NSString)

        // initWithFrame:configuration: 必须在初始化时收到处理器，事后修改 configuration 副本无效。
        typealias Allocate = @convention(c) (AnyClass, Selector) -> Unmanaged<NSObject>
        typealias Initialize = @convention(c) (UnsafeMutableRawPointer, Selector, CGRect, NSObject) -> Unmanaged<NSObject>
        let allocate = unsafeBitCast(method_getImplementation(allocateMethod), to: Allocate.self)
        let instance = allocate(webViewClass, NSSelectorFromString("alloc"))
        let initializeView = unsafeBitCast(method_getImplementation(initializeMethod), to: Initialize.self)
        return initializeView(instance.toOpaque(), initialize, .zero, configuration).takeRetainedValue()
    }
}
#endif
