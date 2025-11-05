// ============================================================================
// WatchSyncManager.swift
// ============================================================================
// 利用 WatchConnectivity 在 iPhone 与 Apple Watch 之间同步应用数据
// - 支持推送（Push）与请求（Pull）两种模式
// - 使用文件传输承载 JSON 同步包，避免消息大小限制
// - 在接收端应用 SyncEngine 合并数据，并根据请求方决定是否回传
// ============================================================================

import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

#if canImport(WatchConnectivity)
@MainActor
public final class WatchSyncManager: NSObject, ObservableObject {
    
    public enum Direction {
        case push  // 当前设备打包数据后推送给对端
        case pull  // 请求对端推送最新数据
    }
    
    public enum SyncState: Equatable {
        case idle
        case syncing(String)
        case success(SyncMergeSummary)
        case failed(String)
    }
    
    public static let shared = WatchSyncManager()
    
    @Published public private(set) var state: SyncState = .idle
    @Published public private(set) var lastSummary: SyncMergeSummary = .empty
    @Published public private(set) var lastUpdatedAt: Date?
    
    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }
    
    private var pendingTransfers: [ObjectIdentifier: SyncOptions] = [:]
    
    private override init() {
        super.init()
        activateSessionIfNeeded()
    }
    
    // MARK: - Public API
    
    public func performSync(direction: Direction, options: SyncOptions) {
        guard let session else {
            state = .failed("此设备不支持 WatchConnectivity。")
            return
        }
        
        guard !options.isEmpty else {
            state = .failed("请至少勾选一项同步内容。")
            return
        }
        
        guard session.isPaired else {
            state = .failed("未检测到已配对的对端设备。")
            return
        }
        
        guard session.isReachable || direction == .push else {
            state = .failed("对端不在线，稍后重试。")
            return
        }
        
        state = .syncing(direction == .push ? "正在发送同步数据…" : "正在请求最新数据…")
        lastSummary = .empty
        
        switch direction {
        case .push:
            sendPackage(options: options, isResponse: false)
        case .pull:
            requestPackage(options: options)
        }
    }
    
    // MARK: - Session Handling
    
    private func activateSessionIfNeeded() {
        guard let session else { return }
        if session.delegate == nil {
            session.delegate = self
        }
        if session.activationState == .notActivated {
            session.activate()
        }
    }
    
    private func requestPackage(options: SyncOptions) {
        guard let session else { return }
        let requestID = UUID()
        
        let message: [String: Any] = [
            "type": "syncRequest",
            "id": requestID.uuidString,
            "options": options.rawValue
        ]
        
        session.sendMessage(message, replyHandler: { [weak self] _ in
            Task { @MainActor in
                self?.state = .syncing("等待对端回传数据…")
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.state = .failed("请求失败: \(error.localizedDescription)")
            }
        })
    }
    
    private func sendPackage(options: SyncOptions, isResponse: Bool, requestID: String? = nil) {
        guard let session else { return }
        let package = SyncEngine.buildPackage(options: options)
        guard let data = try? JSONEncoder().encode(package) else {
            state = .failed("无法编码同步数据。")
            return
        }
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString).json")
        do {
            try data.write(to: tempURL, options: [.atomic])
        } catch {
            state = .failed("写入同步文件失败: \(error.localizedDescription)")
            return
        }
        
        var metadata: [String: Any] = [
            "options": options.rawValue,
            "response": isResponse,
            "timestamp": Date().timeIntervalSince1970
        ]
        if let requestID {
            metadata["requestID"] = requestID
        }
        
        let transfer = session.transferFile(tempURL, metadata: metadata)
        pendingTransfers[ObjectIdentifier(transfer)] = options
    }
    
    private func applyPackage(
        from url: URL,
        isResponse: Bool,
        requestID: String?
    ) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let package = try decoder.decode(SyncPackage.self, from: data)
            let summary = SyncEngine.apply(package: package)
            lastSummary = summary
            lastUpdatedAt = Date()
            
            if summary == .empty {
                state = .success(summary)
            } else {
                state = .success(summary)
            }
            
            if !isResponse {
                // 主动回传对端最新数据，避免单向更新
                sendPackage(options: package.options, isResponse: true)
            } else {
                state = .success(summary)
            }
            
            if let idString = requestID, let uuid = UUID(uuidString: idString) {
                // 清理已完成的请求（目前仅用于日志占位，后续可扩展）
                _ = uuid
            }
        } catch {
            state = .failed("解析同步包失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSyncManager: WCSessionDelegate {
    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            state = .failed("会话激活失败: \(error.localizedDescription)")
        }
    }
    
#if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
#endif
    
    public func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        Task { @MainActor in
            let isResponse = (file.metadata?["response"] as? Bool) ?? false
            let requestID = file.metadata?["requestID"] as? String
            applyPackage(from: file.fileURL, isResponse: isResponse, requestID: requestID)
        }
    }
    
    public func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        Task { @MainActor in
            let identifier = ObjectIdentifier(fileTransfer)
            defer { pendingTransfers.removeValue(forKey: identifier) }
            
            if let error {
                state = .failed("发送失败: \(error.localizedDescription)")
            } else {
                state = .syncing("等待对端处理…")
            }
        }
    }
    
    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String : Any],
        replyHandler: @escaping ([String : Any]) -> Void
    ) {
        guard let type = message["type"] as? String, type == "syncRequest" else {
            replyHandler([:])
            return
        }
        
        let optionsValue = message["options"] as? Int ?? 0
        let requestID = message["id"] as? String
        let options = SyncOptions(rawValue: optionsValue)
        
        Task { @MainActor in
            state = .syncing("收到同步请求，正在准备数据…")
            sendPackage(options: options, isResponse: false, requestID: requestID)
            replyHandler(["status": "processing"])
        }
    }
}
#endif
