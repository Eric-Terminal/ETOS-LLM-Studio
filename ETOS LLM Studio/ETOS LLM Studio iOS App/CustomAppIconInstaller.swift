// ============================================================================
// CustomAppIconInstaller.swift
// ============================================================================
// 自定义主屏幕图标的图片处理、描述文件生成与一次性本地下载服务
// ============================================================================

import Combine
import Foundation
import ImageIO
import Network
import UIKit
import UniformTypeIdentifiers

nonisolated struct PreparedCustomAppIconImage: @unchecked Sendable {
    let image: UIImage
}

nonisolated struct RenderedCustomAppIcon: @unchecked Sendable {
    let image: UIImage
    let pngData: Data
}

nonisolated enum CustomAppIconImageError: Error, Sendable {
    case unreadableImage
    case renderFailed
}

nonisolated enum CustomAppIconImageProcessor {
    static let outputPixelSize = 400
    private static let editingMaximumPixelSize = 2_048

    /// 先在后台完成方向校正和降采样，避免把原始相册大图带进 SwiftUI 渲染链路。
    static func prepareImage(from data: Data) throws -> PreparedCustomAppIconImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CustomAppIconImageError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: editingMaximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CustomAppIconImageError.unreadableImage
        }
        return PreparedCustomAppIconImage(image: UIImage(cgImage: image, scale: 1, orientation: .up))
    }

    /// Web Clip 建议图标不超过 400×400；固定输出尺寸也让未压缩像素数据保持在 1 MB 内。
    static func renderIcon(
        from preparedImage: PreparedCustomAppIconImage,
        cropRect: CGRect
    ) throws -> RenderedCustomAppIcon {
        guard let sourceImage = preparedImage.image.cgImage else {
            throw CustomAppIconImageError.renderFailed
        }
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(sourceImage.width),
            height: CGFloat(sourceImage.height)
        )
        let boundedCropRect = cropRect.integral.intersection(imageBounds)
        guard boundedCropRect.width > 1,
              boundedCropRect.height > 1,
              let croppedImage = sourceImage.cropping(to: boundedCropRect) else {
            throw CustomAppIconImageError.renderFailed
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: outputPixelSize,
            height: outputPixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw CustomAppIconImageError.renderFailed
        }
        context.interpolationQuality = .high
        context.draw(
            croppedImage,
            in: CGRect(x: 0, y: 0, width: outputPixelSize, height: outputPixelSize)
        )
        guard let renderedImage = context.makeImage() else {
            throw CustomAppIconImageError.renderFailed
        }

        let pngData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            pngData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CustomAppIconImageError.renderFailed
        }
        CGImageDestinationAddImage(destination, renderedImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CustomAppIconImageError.renderFailed
        }

        return RenderedCustomAppIcon(
            image: UIImage(cgImage: renderedImage, scale: 1, orientation: .up),
            pngData: pngData as Data
        )
    }
}

nonisolated enum CustomAppIconProfileError: LocalizedError, Sendable {
    case invalidIcon
    case serializationFailed

    var errorDescription: String? {
        switch self {
        case .invalidIcon:
            return NSLocalizedString("图标图片无效，请重新选择。", comment: "自定义主屏幕图标图片无效")
        case .serializationFailed:
            return NSLocalizedString("无法生成图标描述文件。", comment: "自定义主屏幕图标描述文件生成失败")
        }
    }
}

nonisolated enum CustomAppIconProfileBuilder {
    static let profileIdentifier = "com.ericterminal.els.custom-home-screen-icon"
    static let profileUUID = "B8CC1A7D-6F32-4EB8-A58F-74A2E0CD3D75"
    static let webClipIdentifier = "com.ericterminal.els.custom-home-screen-icon.webclip"
    static let webClipUUID = "FE3B8E08-A130-42E9-987F-B523472918C8"
    static let appLaunchURL = "etosllmstudio://open/app"

    static func makeProfile(
        iconPNGData: Data,
        label: String,
        profileDescription: String
    ) throws -> Data {
        guard !iconPNGData.isEmpty, iconPNGData.count < 1_000_000 else {
            throw CustomAppIconProfileError.invalidIcon
        }

        let webClipPayload: [String: Any] = [
            "FullScreen": false,
            "Icon": iconPNGData,
            "IsRemovable": true,
            "Label": label,
            "Precomposed": true,
            "URL": appLaunchURL,
            "PayloadDescription": profileDescription,
            "PayloadDisplayName": label,
            "PayloadIdentifier": webClipIdentifier,
            "PayloadType": "com.apple.webClip.managed",
            "PayloadUUID": webClipUUID,
            "PayloadVersion": 1
        ]
        let profile: [String: Any] = [
            "PayloadContent": [webClipPayload],
            "PayloadDescription": profileDescription,
            "PayloadDisplayName": label,
            "PayloadIdentifier": profileIdentifier,
            "PayloadOrganization": "ETOS LLM Studio",
            "PayloadType": "Configuration",
            "PayloadUUID": profileUUID,
            "PayloadVersion": 1
        ]

        do {
            return try PropertyListSerialization.data(
                fromPropertyList: profile,
                format: .xml,
                options: 0
            )
        } catch {
            throw CustomAppIconProfileError.serializationFailed
        }
    }
}

nonisolated enum CustomAppIconDownloadError: LocalizedError, Sendable {
    case serverUnavailable(String)
    case invalidDownloadAddress
    case browserUnavailable
    case transferFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .serverUnavailable(let details):
            return String(
                format: NSLocalizedString("无法启动本地下载服务：%@", comment: "自定义主屏幕图标本地服务启动失败"),
                details
            )
        case .invalidDownloadAddress:
            return NSLocalizedString("无法创建本地下载地址。", comment: "自定义主屏幕图标本地地址生成失败")
        case .browserUnavailable:
            return NSLocalizedString("无法打开浏览器，请稍后重试。", comment: "自定义主屏幕图标浏览器打开失败")
        case .transferFailed(let details):
            return String(
                format: NSLocalizedString("描述文件传输失败：%@", comment: "自定义主屏幕图标描述文件传输失败"),
                details
            )
        case .timedOut:
            return NSLocalizedString("等待浏览器下载超时，请重试。", comment: "自定义主屏幕图标下载超时")
        }
    }
}

private actor CustomAppIconProfileServer {
    typealias ReadyHandler = @MainActor @Sendable (URL) -> Void
    typealias CompletionHandler = @MainActor @Sendable (Result<Void, CustomAppIconDownloadError>) -> Void

    private nonisolated static let networkQueue = DispatchQueue(
        label: "com.ericterminal.els.custom-app-icon-server",
        qos: .userInitiated
    )
    private nonisolated static let maximumRequestSize = 64 * 1_024

    private let listener: NWListener
    private let profileData: Data
    private let requestPath: String
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var onReady: ReadyHandler?
    private var onCompletion: CompletionHandler?
    private var isFinished = false

    init(profileData: Data) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.profileData = profileData
        requestPath = "/\(UUID().uuidString.lowercased()).mobileconfig"
    }

    func start(onReady: @escaping ReadyHandler, onCompletion: @escaping CompletionHandler) {
        self.onReady = onReady
        self.onCompletion = onCompletion
        listener.newConnectionLimit = 4
        listener.stateUpdateHandler = { [weak self] state in
            Task {
                await self?.handleListenerState(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        listener.start(queue: Self.networkQueue)
    }

    func stop() {
        guard !isFinished else { return }
        isFinished = true
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        listener.cancel()
        onReady = nil
        onCompletion = nil
    }

    private func handleListenerState(_ state: NWListener.State) async {
        guard !isFinished else { return }
        switch state {
        case .ready:
            guard let port = listener.port else {
                await finish(with: .failure(.invalidDownloadAddress))
                return
            }
            guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(requestPath)") else {
                await finish(with: .failure(.invalidDownloadAddress))
                return
            }
            if let onReady {
                await onReady(url)
            }
        case .failed(let error):
            await finish(with: .failure(.serverUnavailable(error.localizedDescription)))
        case .setup, .waiting, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !isFinished else {
            connection.cancel()
            return
        }
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            Task {
                await self?.removeConnection(identifier)
                await self?.finish(with: .failure(.transferFailed(error.localizedDescription)))
            }
        }
        connection.start(queue: Self.networkQueue)
        receiveRequest(from: connection, identifier: identifier, accumulatedData: Data())
    }

    private func receiveRequest(
        from connection: NWConnection,
        identifier: ObjectIdentifier,
        accumulatedData: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1_024) { [weak self] data, _, isComplete, error in
            Task {
                guard let self else { return }
                if let error {
                    await self.removeConnection(identifier)
                    await self.finish(with: .failure(.transferFailed(error.localizedDescription)))
                    return
                }

                var requestData = accumulatedData
                if let data {
                    requestData.append(data)
                }
                if requestData.count > Self.maximumRequestSize {
                    await self.sendStatus(413, title: "Payload Too Large", to: connection, identifier: identifier)
                    return
                }
                if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                    await self.handleRequest(requestData, from: connection, identifier: identifier)
                } else if isComplete {
                    await self.sendStatus(400, title: "Bad Request", to: connection, identifier: identifier)
                } else {
                    await self.receiveRequest(
                        from: connection,
                        identifier: identifier,
                        accumulatedData: requestData
                    )
                }
            }
        }
    }

    private func handleRequest(
        _ requestData: Data,
        from connection: NWConnection,
        identifier: ObjectIdentifier
    ) async {
        guard let request = String(data: requestData, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            await sendStatus(400, title: "Bad Request", to: connection, identifier: identifier)
            return
        }
        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            await sendStatus(400, title: "Bad Request", to: connection, identifier: identifier)
            return
        }
        let method = String(components[0])
        let requestedPath = String(components[1]).split(separator: "?", maxSplits: 1).first.map(String.init)
        guard (method == "GET" || method == "HEAD"), requestedPath == requestPath else {
            await sendStatus(404, title: "Not Found", to: connection, identifier: identifier)
            return
        }

        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/x-apple-aspen-config",
            "Content-Disposition: attachment; filename=\"ETOS-Custom-Icon.mobileconfig\"",
            "Content-Length: \(profileData.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(headers.utf8)
        if method == "GET" {
            response.append(profileData)
        }
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task {
                guard let self else { return }
                await self.removeConnection(identifier)
                if let error {
                    await self.finish(with: .failure(.transferFailed(error.localizedDescription)))
                } else if method == "GET" {
                    await self.finish(with: .success(()))
                }
            }
        })
    }

    private func sendStatus(
        _ statusCode: Int,
        title: String,
        to connection: NWConnection,
        identifier: ObjectIdentifier
    ) async {
        let body = Data("\(statusCode) \(title)".utf8)
        let headers = [
            "HTTP/1.1 \(statusCode) \(title)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task {
                await self?.removeConnection(identifier)
            }
        })
    }

    private func removeConnection(_ identifier: ObjectIdentifier) {
        connections.removeValue(forKey: identifier)?.cancel()
    }

    private func finish(with result: Result<Void, CustomAppIconDownloadError>) async {
        guard !isFinished else { return }
        isFinished = true
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        listener.cancel()
        let completion = onCompletion
        onReady = nil
        onCompletion = nil
        if let completion {
            await completion(result)
        }
    }
}

@MainActor
final class CustomAppIconInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case startingServer
        case waitingForDownload
        case profileDelivered
    }

    static let shared = CustomAppIconInstaller()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var errorMessage: String?

    private var server: CustomAppIconProfileServer?
    private var backgroundTaskLease: ApplicationBackgroundTaskLease?
    private var timeoutTask: Task<Void, Never>?
    private var installationID: UUID?

    private init() {}

    var isBusy: Bool {
        phase == .startingServer || phase == .waitingForDownload
    }

    func install(profileData: Data) {
        cancelCurrentDownload()
        errorMessage = nil
        phase = .startingServer

        let server: CustomAppIconProfileServer
        do {
            server = try CustomAppIconProfileServer(profileData: profileData)
        } catch {
            fail(with: .serverUnavailable(error.localizedDescription), installationID: nil)
            return
        }

        let installationID = UUID()
        self.installationID = installationID
        self.server = server
        Task {
            await server.start { [weak self] downloadURL in
                self?.openBrowser(downloadURL, installationID: installationID)
            } onCompletion: { [weak self] result in
                self?.handleServerCompletion(result, installationID: installationID)
            }
        }
    }

    func clearError() {
        errorMessage = nil
        if phase != .profileDelivered {
            phase = .idle
        }
    }

    func resetStatus() {
        guard !isBusy else { return }
        errorMessage = nil
        phase = .idle
    }

    private func openBrowser(_ downloadURL: URL, installationID: UUID) {
        guard self.installationID == installationID else { return }
        backgroundTaskLease = ApplicationBackgroundTaskLease(name: "custom-app-icon-profile-download")
        phase = .waitingForDownload
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled else { return }
            self?.fail(with: .timedOut, installationID: installationID)
        }

        UIApplication.shared.open(downloadURL, options: [:]) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                self?.fail(with: .browserUnavailable, installationID: installationID)
            }
        }
    }

    private func handleServerCompletion(
        _ result: Result<Void, CustomAppIconDownloadError>,
        installationID: UUID
    ) {
        guard self.installationID == installationID else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        backgroundTaskLease?.end()
        backgroundTaskLease = nil
        server = nil
        self.installationID = nil

        switch result {
        case .success:
            phase = .profileDelivered
        case .failure(let error):
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    private func fail(with error: CustomAppIconDownloadError, installationID: UUID?) {
        if let installationID, self.installationID != installationID {
            return
        }
        let server = self.server
        Task {
            await server?.stop()
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        backgroundTaskLease?.end()
        backgroundTaskLease = nil
        self.server = nil
        self.installationID = nil
        phase = .idle
        errorMessage = error.localizedDescription
    }

    private func cancelCurrentDownload() {
        let server = self.server
        Task {
            await server?.stop()
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        backgroundTaskLease?.end()
        backgroundTaskLease = nil
        self.server = nil
        installationID = nil
    }
}
