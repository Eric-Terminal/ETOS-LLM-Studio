// ============================================================================
// MCPMacStdioProcess.swift
// ============================================================================
// Process 和全部可变状态只在串行队列访问。DispatchIO 按可读/可写事件处理
// 管道，不在主线程做文件 I/O，也不依赖定时轮询。stderr 始终独立排空。
// ============================================================================

#if os(macOS)
import Darwin
import Foundation

final class MCPMacStdioProcess: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let queue = DispatchQueue(label: "com.etos.mcp.macos-process", qos: .utility)
    private var process: Process?
    private var input: DispatchIO?
    private var output: DispatchIO?
    private var diagnostics: DispatchIO?
    private var decoder = MCPStdioMessageDecoder()
    private var closed = false

    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        stream = pair.stream
        continuation = pair.continuation
    }

    func start(configuration: MCPLocalStdioConfiguration, environment: [String: String]) async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !closed else {
                    result.resume(throwing: CancellationError())
                    return
                }
                do {
                    let workingDirectory = Self.workingDirectory(configuration.workingDirectory)
                    let executable = try Self.resolveExecutable(
                        configuration.command,
                        environment: environment,
                        workingDirectory: workingDirectory
                    )
                    guard configuration.arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
                        throw CocoaError(.fileReadInvalidFileName)
                    }
                    let task = Process()
                    task.executableURL = executable
                    task.arguments = configuration.arguments
                    task.environment = environment
                    task.currentDirectoryURL = workingDirectory
                    let stdin = Pipe()
                    let stdout = Pipe()
                    let stderr = Pipe()
                    task.standardInput = stdin
                    task.standardOutput = stdout
                    task.standardError = stderr
                    task.terminationHandler = { [weak self] task in
                        guard let self else { return }
                        let exitCode = task.terminationStatus
                        // 先让 stdout 已写入的尾帧排空。子进程派生的后台程序可能
                        // 保留管道端点，不能因此让已经退出的 MCP 永远显示为连接中。
                        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                            self?.finish(error: MCPLocalStdioError.processExited(exitCode: exitCode, linuxError: 0))
                        }
                    }
                    process = task

                    input = try makeChannel(stdin.fileHandleForWriting, preventsSIGPIPE: true)
                    output = try makeChannel(stdout.fileHandleForReading)
                    diagnostics = try makeChannel(stderr.fileHandleForReading)
                    try task.run()
                    // 父进程不能保留子进程一侧的端点，否则退出后读端无法得到 EOF。
                    try? stdin.fileHandleForReading.close()
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForWriting.close()
                    readStandardOutput()
                    diagnostics?.read(offset: 0, length: Int.max, queue: queue) { _, _, _ in }
                    result.resume()
                } catch {
                    finish(error: error)
                    result.resume(throwing: error)
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !closed, let input else {
                    result.resume(throwing: MCPClientError.notConnected)
                    return
                }
                do {
                    // SDK 负责 JSON-RPC 内容，边界层保证每次写入只有一个完整帧。
                    let framed = try MCPStdioMessageDecoder.frame(data)
                    let bytes = framed.withUnsafeBytes { DispatchData(bytes: $0) }
                    input.write(offset: 0, data: bytes, queue: queue) { done, _, error in
                        guard done else { return }
                        if error != 0 {
                            result.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(error)))
                        } else {
                            result.resume()
                        }
                    }
                } catch {
                    result.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { result in
            queue.async { [self] in
                finish(error: nil)
                result.resume()
            }
        }
    }

    private func makeChannel(_ handle: FileHandle, preventsSIGPIPE: Bool = false) throws -> DispatchIO {
        let descriptor = dup(handle.fileDescriptor)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if preventsSIGPIPE, fcntl(descriptor, F_SETNOSIGPIPE, 1) < 0 {
            let error = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
            Darwin.close(descriptor)
        }
        channel.setLimit(lowWater: 1)
        try? handle.close()
        return channel
    }

    private func readStandardOutput() {
        output?.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, bytes, error in
            guard let self, !closed else { return }
            do {
                if let bytes, !bytes.isEmpty {
                    for message in try decoder.append(Data(bytes)) {
                        if case .dropped = continuation.yield(message) {
                            // 慢消费者不能让恶意服务端无限堆积内存，也不能静默丢响应。
                            throw MCPStdioFramingError.bufferOverflow
                        }
                    }
                }
                if error != 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
                }
                if done {
                    try decoder.finish()
                    if let process, !process.isRunning {
                        throw MCPLocalStdioError.processExited(exitCode: process.terminationStatus, linuxError: 0)
                    }
                    throw MCPClientError.notConnected
                }
            } catch {
                finish(error: error)
            }
        }
    }

    private func finish(error: Error?) {
        guard !closed else { return }
        closed = true
        continuation.finish(throwing: error)
        input?.close(flags: .stop)
        output?.close(flags: .stop)
        diagnostics?.close(flags: .stop)
        input = nil
        output = nil
        diagnostics = nil
        if let process, process.isRunning {
            process.terminate()
            // 给服务端清理机会；忽略 SIGTERM 的进程也不能在断开后永久留存。
            queue.asyncAfter(deadline: .now() + 2) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
    }

    static func workingDirectory(_ path: String) -> URL {
        // /home/etos 是既有数据库省略 cwd 时的默认值，不修改其序列化表示。
        if path.isEmpty || path == "/home/etos" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func resolveExecutable(
        _ command: String,
        environment: [String: String],
        workingDirectory: URL
    ) throws -> URL {
        guard !command.isEmpty, !command.utf8.contains(0) else {
            throw MCPLocalStdioError.dependencyMissing(command: command, suggestedRecipe: nil)
        }
        let candidates: [URL]
        if command.contains("/") {
            candidates = [URL(fileURLWithPath: (command as NSString).expandingTildeInPath, relativeTo: workingDirectory)]
        } else {
            candidates = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).map {
                URL(fileURLWithPath: String($0), isDirectory: true, relativeTo: workingDirectory)
                    .appendingPathComponent(command)
            }
        }
        guard let executable = candidates.first(where: {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw MCPLocalStdioError.dependencyMissing(command: command, suggestedRecipe: nil)
        }
        return executable.absoluteURL
    }
}
#endif
