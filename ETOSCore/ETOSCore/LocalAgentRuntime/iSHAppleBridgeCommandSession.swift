// ============================================================================
// iSHAppleBridgeCommandSession.swift
// ============================================================================
// ETOS LLM Studio
//
// 结构化命令的回调桥。输出处理闭包在 iSH 后台线程同步返回，从源头形成
// 反压；RuntimeController 会在闭包内立即落盘，而不是等待 SwiftUI 订阅。
// ============================================================================

import Foundation

private final class LocalLinuxCommandResultState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LocalLinuxBridgeCommandResult?
    private var waiters: [CheckedContinuation<LocalLinuxBridgeCommandResult, Never>] = []

    func complete(_ result: LocalLinuxBridgeCommandResult) {
        lock.lock()
        guard value == nil else {
            lock.unlock()
            return
        }
        value = result
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        pending.forEach { $0.resume(returning: result) }
    }

    func wait() async -> LocalLinuxBridgeCommandResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value {
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class LocalLinuxCommandCallbackBridge: @unchecked Sendable {
    let onOutput: @Sendable (LocalLinuxOutputStream, Data, Int32) -> Void
    let result = LocalLinuxCommandResultState()

    init(onOutput: @escaping @Sendable (LocalLinuxOutputStream, Data, Int32) -> Void) {
        self.onOutput = onOutput
    }
}

private func localLinuxCommandStreamCallback(
    context: UnsafeMutableRawPointer?,
    requestID: UInt64,
    rawStream: UInt32,
    bytes: UnsafeRawPointer?,
    length: UInt32,
    terminalError: Int32
) {
    guard let context else { return }
    let bridge = Unmanaged<LocalLinuxCommandCallbackBridge>.fromOpaque(context).takeUnretainedValue()
    let stream: LocalLinuxOutputStream = rawStream == 1 ? .stdout : .stderr
    let data = bytes.map { Data(bytes: $0, count: Int(length)) } ?? Data()
    _ = requestID
    bridge.onOutput(stream, data, terminalError)
}

private func localLinuxCommandCompletionCallback(
    context: UnsafeMutableRawPointer?,
    requestID: UInt64,
    reason: Int32,
    exitCode: Int32,
    terminationSignal: Int32,
    linuxError: Int32,
    stdoutBytes: UInt64,
    stderrBytes: UInt64,
    elapsedMilliseconds: UInt64
) {
    guard let context else { return }
    let bridge = Unmanaged<LocalLinuxCommandCallbackBridge>.fromOpaque(context).takeRetainedValue()
    bridge.result.complete(
        LocalLinuxBridgeCommandResult(
            requestID: requestID,
            completionReason: LocalLinuxCompletionReason(commandBridgeRawValue: reason),
            exitCode: exitCode,
            terminationSignal: terminationSignal,
            linuxError: linuxError,
            stdoutBytes: stdoutBytes,
            stderrBytes: stderrBytes,
            elapsedMilliseconds: elapsedMilliseconds
        )
    )
}

public final class iSHAppleBridgeCommandSession: @unchecked Sendable {
    private let native: UnsafeMutableRawPointer
    private let bridge: LocalLinuxCommandCallbackBridge

    private init(native: UnsafeMutableRawPointer, bridge: LocalLinuxCommandCallbackBridge) {
        self.native = native
        self.bridge = bridge
    }

    deinit {
        _ = etosISHCommandCancel(native)
        etosISHCommandRelease(native)
    }

    static func start(
        requestID: UInt64,
        request: LocalLinuxJobRequest,
        onOutput: @escaping @Sendable (LocalLinuxOutputStream, Data, Int32) -> Void
    ) throws -> iSHAppleBridgeCommandSession {
        guard requestID != 0,
              !request.executable.isEmpty,
              request.arguments.first == request.executable else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Linux 命令必须包含与 executable 一致的 argv[0]。", comment: "Linux argv validation error")
            )
        }
        let timeout = try timeoutMilliseconds(request.timeoutSeconds)
        let outputLimit = request.outputLimitBytes.flatMap { $0 == 0 ? nil : $0 }
            ?? LocalLinuxBridgeConstants.outputLimitDisabled
        let environment = request.environment.keys.sorted().map { key in
            "\(key)=\(request.environment[key] ?? "")"
        }
        let bridge = LocalLinuxCommandCallbackBridge(onOutput: onOutput)
        let retained = Unmanaged.passRetained(bridge)
        var native: UnsafeMutableRawPointer?

        let status: Int32
        do {
            status = try withETOSCString(request.executable) { executable in
                try withETOSCStringVector(request.arguments) { arguments, argumentCount in
                    guard let arguments else {
                        throw LocalLinuxRuntimeError.runtimeUnavailable(
                            NSLocalizedString("Linux 命令缺少 argv。", comment: "Linux argv missing error")
                        )
                    }
                    return try withETOSCStringVector(environment) { environment, environmentCount in
                        try withETOSOptionalCString(request.workingDirectory) { workingDirectory in
                            etosISHCommandStart(
                                requestID,
                                executable,
                                arguments,
                                argumentCount,
                                environment,
                                environmentCount,
                                workingDirectory,
                                timeout,
                                outputLimit,
                                retained.toOpaque(),
                                localLinuxCommandStreamCallback,
                                localLinuxCommandCompletionCallback,
                                &native
                            )
                        }
                    }
                }
            }
        } catch {
            retained.release()
            throw error
        }
        guard status == 0, let native else {
            retained.release()
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "启动结构化命令", linuxError: status)
        }
        return iSHAppleBridgeCommandSession(native: native, bridge: bridge)
    }

    public func send(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                var accepted: UInt32 = 0
                let length = min(data.count - offset, 1_048_576)
                let status = data.withUnsafeBytes { bytes in
                    etosISHCommandWrite(
                        native,
                        bytes.baseAddress?.advanced(by: offset),
                        UInt32(length),
                        &accepted
                    )
                }
                if status == LocalLinuxBridgeConstants.linuxEAGAIN || (status == 0 && accepted == 0) {
                    try await Task<Never, Never>.sleep(nanoseconds: 1_000_000)
                    continue
                }
                guard status == 0 else {
                    throw LocalLinuxRuntimeError.bridgeFailure(operation: "写入命令 stdin", linuxError: status)
                }
                offset += Int(accepted)
            }
        } onCancel: {
            _ = etosISHCommandCancel(native)
        }
    }

    public func finishInput() throws {
        let status = etosISHCommandCloseInput(native)
        guard status == 0 else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "关闭命令 stdin", linuxError: status)
        }
    }

    public func interrupt() throws {
        let status = etosISHCommandInterrupt(native)
        guard status == 0 else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "中断命令", linuxError: status)
        }
    }

    public func cancel() throws {
        let status = etosISHCommandCancel(native)
        guard status == 0 else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "取消命令", linuxError: status)
        }
    }

    public func result() async -> LocalLinuxBridgeCommandResult {
        await withTaskCancellationHandler {
            await bridge.result.wait()
        } onCancel: {
            _ = etosISHCommandCancel(native)
        }
    }

    static func timeoutMilliseconds(_ seconds: Double?) throws -> UInt32 {
        guard let seconds else { return 0 }
        guard seconds.isFinite, seconds >= 0 else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Linux 命令超时时间无效。", comment: "Linux timeout validation error")
            )
        }
        if seconds == 0 { return LocalLinuxBridgeConstants.timeoutDisabled }
        let milliseconds = (seconds * 1_000).rounded(.up)
        guard milliseconds < Double(LocalLinuxBridgeConstants.timeoutDisabled) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Linux 命令超时时间超出桥接可表示范围；设为 0 可关闭超时。", comment: "Linux timeout bridge range error")
            )
        }
        return UInt32(milliseconds)
    }
}
