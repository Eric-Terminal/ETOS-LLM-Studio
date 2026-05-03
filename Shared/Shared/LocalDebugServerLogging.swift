// ============================================================================
// LocalDebugServerLogging.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责本地调试客户端的内存日志队列与系统日志桥接。
// 日志用于 iOS 和 watchOS 调试界面展示连接、传输和命令状态。
// ============================================================================

import Foundation

extension LocalDebugServer {
    /// 添加调试日志
    public func addLog(_ message: String, type: DebugLogEntry.LogType = .info) {
        // 心跳日志只记录到系统日志，不显示在 UI 中，避免占用调试面板空间。
        if type == .heartbeat {
            logger.debug("[\(type)] \(message)")
            return
        }

        let entry = DebugLogEntry(timestamp: Date(), message: message, type: type)
        debugLogs.insert(entry, at: 0)
        if debugLogs.count > maxLogEntries {
            debugLogs.removeLast()
        }
        logger.info("[\(type)] \(message)")
    }

    /// 清空日志
    public func clearLogs() {
        debugLogs.removeAll()
    }
}
