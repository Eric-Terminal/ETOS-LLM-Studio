#if os(macOS)
import Darwin
import Foundation

/// 每个命令拥有独立的 POSIX 会话；管道、PTY、退出与超时都由事件驱动，不轮询主线程。
final class MacNativeProcess: LocalCommandSession, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.etos.native-process", qos: .utility)
    private let requestID: UInt64
    private let onOutput: @Sendable (LocalLinuxOutputStream, Data, Int32) -> Void
    private let started = DispatchTime.now()
    private var pid: pid_t = 0
    private var master: Int32 = -1
    private var input: DispatchIO?
    private var readers: [Int32: (source: DispatchSourceRead, stream: LocalLinuxOutputStream)] = [:]
    private var exitSource: DispatchSourceProcess?
    private var timeout: DispatchSourceTimer?
    private var processExited = false
    private var reason: LocalLinuxCompletionReason?
    private var stdoutBytes: UInt64 = 0
    private var stderrBytes: UInt64 = 0
    private var outputLimit: UInt64?
    private var completed: LocalLinuxBridgeCommandResult?
    private var waiters: [CheckedContinuation<LocalLinuxBridgeCommandResult, Never>] = []

    private init(requestID: UInt64, onOutput: @escaping @Sendable (LocalLinuxOutputStream, Data, Int32) -> Void) {
        self.requestID = requestID
        self.onOutput = onOutput
    }

    static func start(requestID: UInt64, request: LocalLinuxJobRequest,
                      terminalSize: (UInt16, UInt16)? = nil,
                      onOutput: @escaping @Sendable (LocalLinuxOutputStream, Data, Int32) -> Void) throws -> MacNativeProcess {
        let process = MacNativeProcess(requestID: requestID, onOutput: onOutput)
        try process.queue.sync { try process.launch(request, terminalSize: terminalSize) }
        return process
    }

    private func launch(_ request: LocalLinuxJobRequest, terminalSize: (UInt16, UInt16)?) throws {
        guard !request.executable.isEmpty, !request.executable.utf8.contains(0),
              !request.arguments.isEmpty, request.arguments.allSatisfy({ !$0.utf8.contains(0) }),
              request.workingDirectory?.utf8.contains(0) != true else { throw CocoaError(.fileReadInvalidFileName) }
        if let seconds = request.timeoutSeconds, !seconds.isFinite || seconds < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let environment = request.environment.map { "\($0.key)=\($0.value)" }
        guard environment.allSatisfy({ !$0.utf8.contains(0) }) else { throw CocoaError(.fileReadInvalidFileName) }
        let directory = request.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let executable = try MCPMacStdioProcess.resolveExecutable(request.executable,
            environment: request.environment, workingDirectory: directory)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // 新会话使取消操作只作用于本任务；PTY 从子进程内打开，取得自己的控制终端。
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        var descriptors: [Int32] = []
        var launched = false
        defer { if !launched { descriptors.forEach { Darwin.close($0) } } }
        let inputDescriptor: Int32
        var outputDescriptors: [(Int32, LocalLinuxOutputStream)] = []
        if let (columns, rows) = terminalSize {
            var slave: Int32 = -1
            var terminal: Int32 = -1
            var size = winsize(ws_row: max(1, rows), ws_col: max(1, columns), ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&terminal, &slave, nil, nil, &size) == 0 else { throw posixError() }
            descriptors += [terminal, slave]
            guard let name = ttyname(slave) else { throw posixError() }
            let slavePath = String(cString: name)
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slavePath, O_RDWR, 0))
            try check(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO))
            master = terminal
            inputDescriptor = dup(terminal)
            guard inputDescriptor >= 0 else { throw posixError() }
            descriptors.append(inputDescriptor)
            outputDescriptors = [(terminal, .terminal)]
        } else {
            var endpoints: [[Int32]] = []
            for _ in 0..<3 {
                var pair: [Int32] = [-1, -1]
                guard pipe(&pair) == 0 else { throw posixError() }
                descriptors += pair
                endpoints.append(pair)
            }
            try check(posix_spawn_file_actions_adddup2(&actions, endpoints[0][0], STDIN_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, endpoints[1][1], STDOUT_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, endpoints[2][1], STDERR_FILENO))
            inputDescriptor = endpoints[0][1]
            outputDescriptors = [(endpoints[1][0], .stdout), (endpoints[2][0], .stderr)]
        }
        try check(posix_spawn_file_actions_addchdir(&actions, directory.path))
        var arguments = request.arguments.map { strdup($0) } + [nil]
        var variables = environment.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) }; variables.forEach { free($0) } }
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, &arguments, &variables)
        try check(status)
        launched = true
        let kept = Set([inputDescriptor] + outputDescriptors.map(\.0))
        descriptors.filter { !kept.contains($0) }.forEach { Darwin.close($0) }
        _ = fcntl(inputDescriptor, F_SETNOSIGPIPE, 1)
        input = DispatchIO(type: .stream, fileDescriptor: inputDescriptor, queue: queue) { _ in Darwin.close(inputDescriptor) }
        for (descriptor, stream) in outputDescriptors { observeOutput(descriptor, stream: stream) }
        outputLimit = request.outputLimitBytes.flatMap { $0 > 0 ? $0 : nil }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.reap() }
        exitSource = source
        source.resume()
        if let seconds = request.timeoutSeconds, seconds > 0, seconds.isFinite {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + seconds)
            timer.setEventHandler { [weak self] in self?.terminate(reason: .timedOut) }
            timeout = timer
            timer.resume()
        }
    }

    private func observeOutput(_ descriptor: Int32, stream: LocalLinuxOutputStream) {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(descriptor, stream: stream) }
        source.setCancelHandler { Darwin.close(descriptor) }
        readers[descriptor] = (source, stream)
        source.resume()
    }

    private func drain(_ descriptor: Int32, stream: LocalLinuxOutputStream) {
        var bytes = [UInt8](repeating: 0, count: 32_768)
        // 有界 drain 让持续输出的任务也能及时接收超时、取消和输入事件。
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                if stream == .stderr { stderrBytes += UInt64(count) } else { stdoutBytes += UInt64(count) }
                onOutput(stream, Data(bytes.prefix(count)), 0)
                if let outputLimit, stdoutBytes + stderrBytes >= outputLimit { terminate(reason: .outputLimit) }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            // Darwin PTY 的 slave 退出后，master 以 EIO 表达 EOF。
            let error = count < 0 && !(stream == .terminal && errno == EIO) ? errno : 0
            onOutput(stream, Data(), error)
            readers.removeValue(forKey: descriptor)?.source.cancel()
            if descriptor == master { master = -1 }
            finishIfDrained()
            return
        }
    }

    private func reap() {
        processExited = true
        exitSource?.cancel(); exitSource = nil
        input?.close(flags: .stop); input = nil
        finishIfDrained()
    }

    private func finishIfDrained() {
        guard completed == nil, processExited, readers.isEmpty else { return }
        timeout?.cancel(); timeout = nil
        var status: Int32 = 0
        // 排空期间保留已退出子进程的 PID，取消其进程组时不会命中复用的 PID。
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { break }
        }
        let signal = status & 0x7f
        let result = LocalLinuxBridgeCommandResult(requestID: requestID,
            completionReason: reason ?? (signal == 0 ? .exited : .signaled),
            exitCode: signal == 0 ? (status >> 8) & 0xff : 0, terminationSignal: signal, linuxError: 0,
            stdoutBytes: stdoutBytes, stderrBytes: stderrBytes,
            elapsedMilliseconds: (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
        completed = result
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume(returning: result) }
    }

    private func terminate(reason: LocalLinuxCompletionReason) {
        guard completed == nil, self.reason == nil else { return }
        self.reason = reason
        input?.close(flags: .stop); input = nil
        if master >= 0 {
            let foreground = tcgetpgrp(master)
            if foreground > 0 { Darwin.kill(-foreground, SIGHUP); Darwin.kill(-foreground, SIGTERM) }
        }
        Darwin.kill(-pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, completed == nil else { return }
            if master >= 0 {
                let foreground = tcgetpgrp(master)
                if foreground > 0, getsid(foreground) == pid { Darwin.kill(-foreground, SIGKILL) }
            }
            Darwin.kill(-pid, SIGKILL)
            // 后台程序可能继承管道后脱离原进程组。取消不能无限等待这些描述符的 EOF。
            for descriptor in Array(readers.keys) {
                guard let stream = readers[descriptor]?.stream else { continue }
                drain(descriptor, stream: stream)
                if let reader = readers.removeValue(forKey: descriptor) {
                    reader.source.cancel()
                    onOutput(stream, Data(), 0)
                }
            }
            master = -1
            finishIfDrained()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let input, !processExited else { continuation.resume(throwing: CocoaError(.fileWriteUnknown)); return }
                let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
                input.write(offset: 0, data: bytes, queue: queue) { done, _, error in
                    guard done else { return }
                    if error == 0 { continuation.resume() }
                    else { continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(error))) }
                }
            }
        }
    }

    func finishInput() throws {
        queue.async { [self] in input?.close(); input = nil }
    }

    func interrupt() throws {
        queue.async { [self] in
            guard !processExited else { return }
            let foreground = master >= 0 ? tcgetpgrp(master) : pid
            if foreground > 0 { Darwin.kill(-foreground, SIGINT) }
        }
    }

    func cancel() throws { queue.async { [self] in terminate(reason: .cancelled) } }

    func resize(columns: UInt16, rows: UInt16) throws {
        try queue.sync {
            guard master >= 0 else { throw CocoaError(.fileWriteUnknown) }
            var size = winsize(ws_row: max(1, rows), ws_col: max(1, columns), ws_xpixel: 0, ws_ypixel: 0)
            guard ioctl(master, TIOCSWINSZ, &size) == 0 else { throw posixError() }
        }
    }

    func result() async -> LocalLinuxBridgeCommandResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let completed { continuation.resume(returning: completed) }
                else { waiters.append(continuation) }
            }
        }
    }

    private func check(_ status: Int32) throws {
        if status != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
    }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

final class MacNativeTerminalSession: LocalTerminalSession, @unchecked Sendable {
    private let process: MacNativeProcess
    init(request: LocalLinuxBridgeTerminalRequest, onOutput: @escaping @Sendable (Data, UInt64) -> Void) throws {
        process = try MacNativeProcess.start(requestID: request.terminalID,
            request: LocalLinuxJobRequest(executable: request.executable, arguments: request.arguments,
                environment: request.environment, workingDirectory: request.workingDirectory),
            terminalSize: (request.columns, request.rows), onOutput: { _, data, _ in onOutput(data, 0) })
    }
    func send(_ data: Data) async throws { try await process.send(data) }
    func finishInput() throws { Task { try? await process.send(Data([4])) } }
    func interrupt() throws { try process.interrupt() }
    func cancel() throws { try process.cancel() }
    func resize(columns: UInt16, rows: UInt16) throws { try process.resize(columns: columns, rows: rows) }
    func result() async throws -> LocalLinuxBridgeTerminalResult {
        let result = await process.result()
        return LocalLinuxBridgeTerminalResult(terminalID: result.requestID, completionReason: result.completionReason,
            exitCode: result.exitCode, terminationSignal: result.terminationSignal, linuxError: result.linuxError,
            outputBytes: result.stdoutBytes, droppedBytes: 0, elapsedMilliseconds: result.elapsedMilliseconds)
    }
}
#endif
