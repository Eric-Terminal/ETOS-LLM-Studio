// ============================================================================
// iSHAppleBridgeTerminalSession.swift
// ============================================================================
// ETOS LLM Studio
//
// 完整 PTY 会话使用独立控制终端。轮询任务始终在后台 drain raw output，
// 页面关闭或未显示时也不会停止读取。
// ============================================================================

import Foundation

private final class LocalLinuxTerminalResultState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<LocalLinuxBridgeTerminalResult, Error>?
    private var waiters: [CheckedContinuation<LocalLinuxBridgeTerminalResult, Error>] = []

    func complete(_ result: LocalLinuxBridgeTerminalResult) {
        resolve(.success(result))
    }

    func fail(_ error: Error) {
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<LocalLinuxBridgeTerminalResult, Error>) {
        lock.lock()
        guard value == nil else {
            lock.unlock()
            return
        }
        value = result
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        pending.forEach { $0.resume(with: result) }
    }

    func wait() async throws -> LocalLinuxBridgeTerminalResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let value {
                lock.unlock()
                continuation.resume(with: value)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class LocalLinuxRetainedTerminalHandle: @unchecked Sendable {
    let native: UnsafeMutableRawPointer

    init?(_ native: UnsafeMutableRawPointer) {
        guard let retained = etosISHTerminalRetain(native) else { return nil }
        self.native = retained
    }

    deinit {
        etosISHTerminalRelease(native)
    }
}

public final class iSHAppleBridgeTerminalSession: @unchecked Sendable {
    private let native: UnsafeMutableRawPointer
    private let resultState = LocalLinuxTerminalResultState()
    private let taskLock = NSLock()
    private var pollingTask: Task<Void, Never>?

    private init(
        native: UnsafeMutableRawPointer,
        terminalID: UInt64,
        onOutput: @escaping @Sendable (Data, UInt64) -> Void
    ) throws {
        self.native = native
        guard let retained = LocalLinuxRetainedTerminalHandle(native) else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "保留交互终端", linuxError: -1)
        }
        let resultState = resultState
        let task = Task.detached(priority: .utility) {
            var buffer = [UInt8](repeating: 0, count: LocalLinuxBridgeConstants.outputChunkBytes)
            while !Task.isCancelled {
                var count: UInt32 = 0
                var dropped: UInt64 = 0
                let readStatus = buffer.withUnsafeMutableBytes { bytes in
                    etosISHTerminalRead(
                        retained.native,
                        bytes.baseAddress,
                        UInt32(bytes.count),
                        &count,
                        &dropped
                    )
                }
                if readStatus == 0, count != 0 || dropped != 0 {
                    onOutput(Data(buffer.prefix(Int(count))), dropped)
                } else if readStatus != 0, readStatus != LocalLinuxBridgeConstants.linuxESHUTDOWN {
                    resultState.fail(
                        LocalLinuxRuntimeError.bridgeFailure(operation: "读取交互终端输出", linuxError: readStatus)
                    )
                    return
                }

                var resultTerminalID: UInt64 = 0
                var reason: Int32 = 0
                var exitCode: Int32 = 0
                var signal: Int32 = 0
                var linuxError: Int32 = 0
                var outputBytes: UInt64 = 0
                var droppedBytes: UInt64 = 0
                var elapsedMilliseconds: UInt64 = 0
                let resultStatus = etosISHTerminalResult(
                    retained.native,
                    &resultTerminalID,
                    &reason,
                    &exitCode,
                    &signal,
                    &linuxError,
                    &outputBytes,
                    &droppedBytes,
                    &elapsedMilliseconds
                )
                if resultStatus == 0, count == 0, dropped == 0 {
                    resultState.complete(
                        LocalLinuxBridgeTerminalResult(
                            terminalID: resultTerminalID,
                            completionReason: LocalLinuxCompletionReason(terminalBridgeRawValue: reason),
                            exitCode: exitCode,
                            terminationSignal: signal,
                            linuxError: linuxError,
                            outputBytes: outputBytes,
                            droppedBytes: droppedBytes,
                            elapsedMilliseconds: elapsedMilliseconds
                        )
                    )
                    return
                }
                if resultStatus != 0, resultStatus != LocalLinuxBridgeConstants.linuxEAGAIN {
                    resultState.fail(
                        LocalLinuxRuntimeError.bridgeFailure(operation: "读取交互终端结果", linuxError: resultStatus)
                    )
                    return
                }
                try? await Task<Never, Never>.sleep(nanoseconds: 5_000_000)
            }
        }
        taskLock.lock()
        pollingTask = task
        taskLock.unlock()
        _ = terminalID
    }

    deinit {
        taskLock.lock()
        let task = pollingTask
        pollingTask = nil
        taskLock.unlock()
        task?.cancel()
        _ = etosISHTerminalCancel(native)
        etosISHTerminalRelease(native)
    }

    static func start(
        request: LocalLinuxBridgeTerminalRequest,
        onOutput: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> iSHAppleBridgeTerminalSession {
        guard request.terminalID != 0,
              !request.executable.isEmpty,
              request.arguments.first == request.executable,
              request.columns != 0,
              request.rows != 0 else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("交互终端参数无效。", comment: "Linux terminal validation error")
            )
        }
        let environment = request.environment.keys.sorted().map { key in
            "\(key)=\(request.environment[key] ?? "")"
        }
        var native: UnsafeMutableRawPointer?
        let status = try withETOSCString(request.executable) { executable in
            try withETOSCStringVector(request.arguments) { arguments, argumentCount in
                guard let arguments else {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("交互终端缺少 argv。", comment: "Linux terminal argv missing error")
                    )
                }
                return try withETOSCStringVector(environment) { environment, environmentCount in
                    try withETOSOptionalCString(request.workingDirectory) { workingDirectory in
                        etosISHTerminalStart(
                            request.terminalID,
                            executable,
                            arguments,
                            argumentCount,
                            environment,
                            environmentCount,
                            workingDirectory,
                            request.columns,
                            request.rows,
                            &native
                        )
                    }
                }
            }
        }
        guard status == 0, let native else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "启动交互终端", linuxError: status)
        }
        do {
            return try iSHAppleBridgeTerminalSession(
                native: native,
                terminalID: request.terminalID,
                onOutput: onOutput
            )
        } catch {
            _ = etosISHTerminalCancel(native)
            etosISHTerminalRelease(native)
            throw error
        }
    }

    public func send(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                var accepted: UInt32 = 0
                let length = min(data.count - offset, 1_048_576)
                let status = data.withUnsafeBytes { bytes in
                    etosISHTerminalWrite(
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
                    throw LocalLinuxRuntimeError.bridgeFailure(operation: "写入交互终端", linuxError: status)
                }
                offset += Int(accepted)
            }
        } onCancel: {
            _ = etosISHTerminalCancel(native)
        }
    }

    public func finishInput() throws {
        let status = etosISHTerminalFinishInput(native)
        guard status == 0 else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "结束交互终端输入", linuxError: status)
        }
    }

    public func resize(columns: UInt16, rows: UInt16) throws {
        let status = etosISHTerminalResize(native, columns, rows)
        guard status == 0 else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "调整交互终端尺寸", linuxError: status)
        }
    }

    public func interrupt() throws {
        let status = etosISHTerminalInterrupt(native)
        guard status == 0 else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "中断交互终端", linuxError: status)
        }
    }

    public func cancel() throws {
        let status = etosISHTerminalCancel(native)
        guard status == 0 else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "取消交互终端", linuxError: status)
        }
    }

    public func result() async throws -> LocalLinuxBridgeTerminalResult {
        try await withTaskCancellationHandler {
            try await resultState.wait()
        } onCancel: {
            _ = etosISHTerminalCancel(native)
        }
    }
}
