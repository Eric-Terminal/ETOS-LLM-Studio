// ============================================================================
// LocalLinuxOutputCollector.swift
// ============================================================================
// ETOS LLM Studio
//
// 原始输出用带 stream 标记的二进制帧持续落盘；模型副本独立执行环境值脱敏
// 和有界预览。用户看到的原始日志不会被改写。
// ============================================================================

import Foundation

public struct LocalLinuxOutputSnapshot: Equatable, Sendable {
    public let stdoutBytes: UInt64
    public let stderrBytes: UInt64
    public let terminalBytes: UInt64
    public let modelBytes: UInt64
    public let didRedact: Bool
    public let didTruncateModelOutput: Bool
    public let writeError: String?
}

public final class LocalLinuxOutputCollector: @unchecked Sendable {
    private struct RedactionPattern {
        let value: Data
        let replacement: Data
    }

    private let lock = NSLock()
    // 写入者先取得输出锁，再短暂取得屏幕锁；预览读取只取得屏幕锁，不等待磁盘 I/O。
    private let presentationLock = NSLock()
    private let rawHandle: FileHandle
    private let modelHandle: FileHandle
    private let patterns: [RedactionPattern]
    private let privacyEnabled: Bool
    private let maximumPatternBytes: Int
    private let modelByteLimit: UInt64
    private let terminalResponseHandler: (@Sendable (Data) -> Void)?

    private var pendingByStream: [LocalLinuxOutputStream: Data] = [:]
    private var stdoutBytes: UInt64 = 0
    private var stderrBytes: UInt64 = 0
    private var terminalBytes: UInt64 = 0
    private var modelBytes: UInt64 = 0
    private var lastModelStream: LocalLinuxOutputStream?
    private var didRedact = false
    private var didTruncate = false
    private var writeError: Error?
    private var isFinished = false
    private var userPreview = Data()
    private var userPreviewNeedsRefresh = false
    private var lastUserPreviewStream: LocalLinuxOutputStream?
    private let userPreviewLimit = 262_144
    private var terminalScreen: LocalLinuxTerminalScreen?
    private var terminalPresentation: LocalLinuxTerminalPresentation?
    private var terminalPresentationAppearance: LocalLinuxTerminalAppearance?
    private var terminalPresentationNeedsRefresh = false
    private var terminalPreviewPresentation: LocalLinuxTerminalPresentation?
    private var terminalPreviewMaximumLines = 0
    private var terminalPreviewAppearance: LocalLinuxTerminalAppearance?
    private var terminalPreviewNeedsRefresh = false
    private var terminalDiagnosticSummaries: [String] = []
    private let terminalChanges = LocalLinuxTerminalChanges()
    private let diagnosticLineIDs = (0..<4).map { _ in UUID() }

    public init(
        rawURL: URL,
        modelURL: URL,
        redactionValues: [String],
        privacyEnabled: Bool,
        modelByteLimit: UInt64,
        terminalColumns: Int? = nil,
        terminalRows: Int? = nil,
        terminalResponseHandler: (@Sendable (Data) -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        fileManager.createFile(atPath: rawURL.path, contents: nil)
        fileManager.createFile(atPath: modelURL.path, contents: nil)
        rawHandle = try FileHandle(forWritingTo: rawURL)
        modelHandle = try FileHandle(forWritingTo: modelURL)
        patterns = Array(Set(redactionValues.filter { $0.count >= 5 })).map { value in
            let replacement: String
            if value.count < 8 {
                replacement = String(repeating: "*", count: value.count)
            } else {
                replacement = String(value.prefix(2))
                    + String(repeating: "*", count: value.count - 4)
                    + String(value.suffix(2))
            }
            return RedactionPattern(value: Data(value.utf8), replacement: Data(replacement.utf8))
        }.sorted { $0.value.count > $1.value.count }
        self.privacyEnabled = privacyEnabled
        maximumPatternBytes = privacyEnabled ? (patterns.first?.value.count ?? 0) : 0
        self.modelByteLimit = modelByteLimit
        self.terminalResponseHandler = terminalResponseHandler
        if let terminalColumns, let terminalRows {
            terminalScreen = LocalLinuxTerminalScreen(
                columns: terminalColumns,
                rows: terminalRows
            )
            terminalPresentation = .empty
            terminalPreviewPresentation = .empty
        }
    }

    deinit {
        finish()
    }

    public func append(
        stream: LocalLinuxOutputStream,
        data: Data,
        terminalError: Int32 = 0,
        streamEnded: Bool = false
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        do {
            if !data.isEmpty {
                try writeRawFrame(stream: stream, data: data)
                appendUserPreview(stream: stream, data: data)
                switch stream {
                case .stdout: stdoutBytes += UInt64(data.count)
                case .stderr: stderrBytes += UInt64(data.count)
                case .terminal: terminalBytes += UInt64(data.count)
                }
                appendModelBytes(stream: stream, data: data, flush: false)
            }
            if streamEnded || terminalError != 0 {
                appendModelBytes(stream: stream, data: Data(), flush: true)
            }
        } catch {
            writeError = writeError ?? error
        }
    }

    /// 兼容性诊断是宿主注解，不写回 PTY 字节流；这样不会扰乱 guest 的光标与行编辑状态。
    public func appendTerminalDiagnostic(_ event: LocalLinuxBridgeDiagnosticEvent) {
        let summary = LocalLinuxDiagnosticPresentation.userSummary(event)
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        presentationLock.lock()
        if terminalDiagnosticSummaries.last != summary {
            terminalDiagnosticSummaries.append(summary)
            terminalDiagnosticSummaries = Array(terminalDiagnosticSummaries.suffix(3))
        }
        presentationLock.unlock()
        appendModelBytes(
            stream: .terminal,
            data: Data("\n\(summary)\n".utf8),
            flush: true
        )
        terminalChanges.send()
    }

    public func finish(completeTerminalUpdates: Bool = true) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            if completeTerminalUpdates { terminalChanges.finish() }
            return
        }
        isFinished = true
        do {
            for stream in [LocalLinuxOutputStream.stdout, .stderr, .terminal] {
                appendModelBytes(stream: stream, data: Data(), flush: true)
            }
            if didRedact {
                let notice = NSLocalizedString(
                    "\n[隐私模式已按环境变量值打码；用户原始日志未被修改]\n",
                    comment: "Linux model output redaction notice"
                )
                try writeModel(Data(notice.utf8), ignoresLimit: true)
            }
            if didTruncate {
                let notice = NSLocalizedString(
                    "\n[模型输出已截断；完整原始日志仍保存在任务附件中]\n",
                    comment: "Linux model output truncation notice"
                )
                try writeModel(Data(notice.utf8), ignoresLimit: true)
            }
            try rawHandle.synchronize()
            try modelHandle.synchronize()
            try rawHandle.close()
            try modelHandle.close()
        } catch {
            writeError = writeError ?? error
        }
        lock.unlock()
        if completeTerminalUpdates { terminalChanges.finish() }
    }

    /// 调度器先保存最终任务状态，再结束页面订阅，确保最后一帧与退出状态一致。
    func finishTerminalUpdates() { terminalChanges.finish() }

    func terminalDisplayUpdates(
        appearance: LocalLinuxTerminalAppearance,
        minimumInterval: Duration
    ) -> AsyncStream<[LocalLinuxTerminalDisplayLine]> {
        let changes = terminalChanges.stream()
        let (stream, continuation) = AsyncStream<[LocalLinuxTerminalDisplayLine]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        // 订阅持有收集器直到最后一帧发送完成；页面取消会同时取消这个任务。
        let task = Task.detached(priority: .utility) { [self] in
            for await _ in changes {
                guard !Task.isCancelled else { break }
                continuation.yield(self.terminalDisplayLines(appearance: appearance))
                // 只在有输出后合并短时间内的变化；空闲时没有周期性唤醒。
                do { try await Task<Never, Never>.sleep(for: minimumInterval) }
                catch { break }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func terminalDisplayLines(appearance: LocalLinuxTerminalAppearance) -> [LocalLinuxTerminalDisplayLine] {
        presentationLock.lock()
        defer { presentationLock.unlock() }
        var lines = terminalScreen?.renderedDisplayLines(appearance: appearance) ?? []
        if !terminalDiagnosticSummaries.isEmpty {
            for (index, summary) in (terminalDiagnosticSummaries + [LocalLinuxDiagnosticPresentation.userGuidance]).enumerated() {
                lines.append(LocalLinuxTerminalDisplayLine(
                    id: diagnosticLineIDs[index], plainText: summary, attributedText: AttributedString(summary)
                ))
            }
        }
        return lines
    }

    public func snapshot() -> LocalLinuxOutputSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return LocalLinuxOutputSnapshot(
            stdoutBytes: stdoutBytes,
            stderrBytes: stderrBytes,
            terminalBytes: terminalBytes,
            modelBytes: modelBytes,
            didRedact: didRedact,
            didTruncateModelOutput: didTruncate,
            writeError: writeError?.localizedDescription
        )
    }

    public func userVisiblePreview() -> String {
        presentationLock.lock()
        defer { presentationLock.unlock() }
        refreshUserPreviewIfNeeded()
        return String(decoding: userPreview, as: UTF8.self)
    }

    private func refreshUserPreviewIfNeeded() {
        if userPreviewNeedsRefresh, let terminalScreen {
            userPreview = Data(terminalScreen.renderedText().utf8)
            if userPreview.count > userPreviewLimit {
                userPreview.removeFirst(userPreview.count - userPreviewLimit)
            }
            userPreviewNeedsRefresh = false
        }
    }

    public func userVisibleTerminalPresentation(
        appearance: LocalLinuxTerminalAppearance = .dark
    ) -> LocalLinuxTerminalPresentation? {
        presentationLock.lock()
        defer { presentationLock.unlock() }
        if terminalPresentationNeedsRefresh
            || terminalPresentationAppearance != appearance,
           let terminalScreen {
            terminalPresentation = terminalScreen.renderedPresentation(appearance: appearance)
            terminalPresentationAppearance = appearance
            terminalPresentationNeedsRefresh = false
        }
        return terminalPresentation.map(presentationWithDiagnostics)
    }

    /// 浮窗只需要末尾少量屏幕行，避免每次刷新都复制完整回滚缓冲区。
    public func userVisibleTerminalPreviewPresentation(
        maximumLines: Int,
        appearance: LocalLinuxTerminalAppearance = .dark
    ) -> LocalLinuxTerminalPresentation? {
        presentationLock.lock()
        defer { presentationLock.unlock() }
        let normalizedMaximumLines = max(1, maximumLines)
        if terminalPreviewNeedsRefresh
            || terminalPreviewMaximumLines != normalizedMaximumLines
            || terminalPreviewAppearance != appearance,
           let terminalScreen {
            terminalPreviewPresentation = terminalScreen.renderedPresentation(
                maximumLines: normalizedMaximumLines,
                appearance: appearance
            )
            terminalPreviewMaximumLines = normalizedMaximumLines
            terminalPreviewAppearance = appearance
            terminalPreviewNeedsRefresh = false
        }
        return terminalPreviewPresentation.map(presentationWithDiagnostics)
    }

    public func resizeTerminalPreview(columns: Int, rows: Int) {
        presentationLock.lock()
        defer { presentationLock.unlock() }
        terminalScreen?.resize(columns: columns, rows: rows)
        invalidateTerminalPresentations()
    }

    private func writeRawFrame(stream: LocalLinuxOutputStream, data: Data) throws {
        let marker: UInt8
        switch stream {
        case .stdout: marker = 1
        case .stderr: marker = 2
        case .terminal: marker = 3
        }
        var length = UInt32(data.count).bigEndian
        var frame = Data(capacity: 5 + data.count)
        frame.append(marker)
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(data)
        try rawHandle.write(contentsOf: frame)
    }

    private func appendUserPreview(stream: LocalLinuxOutputStream, data: Data) {
        presentationLock.lock()
        defer { presentationLock.unlock() }
        if stream == .terminal, let terminalScreen {
            terminalScreen.append(data)
            invalidateTerminalPresentations()
            let responses = terminalScreen.drainResponses()
            if !responses.isEmpty { terminalResponseHandler?(responses) }
            lastUserPreviewStream = stream
            return
        }
        refreshUserPreviewIfNeeded()
        if stream != .terminal, lastUserPreviewStream != stream {
            let label = stream == .stdout ? "\n[stdout]\n" : "\n[stderr]\n"
            userPreview.append(contentsOf: label.utf8)
        }
        userPreview.append(data)
        lastUserPreviewStream = stream
        if userPreview.count > userPreviewLimit {
            userPreview.removeFirst(userPreview.count - userPreviewLimit)
        }
    }

    private func invalidateTerminalPresentations() {
        // 协议解析和回包必须持续进行；完整历史的拼接只在读取预览时执行，
        // 避免隐藏终端的每个输出分片都重复复制最多 2,000 行文本。
        userPreviewNeedsRefresh = true
        terminalPresentationNeedsRefresh = true
        terminalPreviewNeedsRefresh = true
        terminalChanges.send()
    }

    private func presentationWithDiagnostics(
        _ presentation: LocalLinuxTerminalPresentation
    ) -> LocalLinuxTerminalPresentation {
        guard !terminalDiagnosticSummaries.isEmpty else { return presentation }
        let summaries = terminalDiagnosticSummaries.joined(separator: "\n")
            + "\n"
            + LocalLinuxDiagnosticPresentation.userGuidance
        let separator = presentation.plainText.isEmpty ? "" : "\n"
        var attributedText = presentation.attributedText
        attributedText.append(AttributedString(separator + summaries))
        return LocalLinuxTerminalPresentation(
            plainText: presentation.plainText + separator + summaries,
            attributedText: attributedText
        )
    }

    private func appendModelBytes(stream: LocalLinuxOutputStream, data: Data, flush: Bool) {
        // 模型副本满额后不再扫描或保留跨分片尾部；原始输出和终端协议仍照常处理。
        guard modelBytes < modelByteLimit else {
            if !data.isEmpty || pendingByStream.values.contains(where: { !$0.isEmpty }) {
                didTruncate = true
            }
            pendingByStream.removeAll(keepingCapacity: true)
            return
        }
        var combined = pendingByStream[stream, default: Data()]
        combined.append(data)
        var cutoff = flush || maximumPatternBytes == 0
            ? combined.count
            : max(0, combined.count - maximumPatternBytes + 1)

        if cutoff > 0, privacyEnabled {
            for pattern in patterns where pattern.value.count > 0 {
                for range in combined.ranges(of: pattern.value) where range.lowerBound < cutoff && range.upperBound > cutoff {
                    cutoff = min(cutoff, range.lowerBound)
                }
            }
        }

        let ready = Data(combined.prefix(cutoff))
        pendingByStream[stream] = Data(combined.dropFirst(cutoff))
        guard !ready.isEmpty else { return }
        do {
            if lastModelStream != stream {
                let label = switch stream {
                case .stdout: "\n[stdout]\n"
                case .stderr: "\n[stderr]\n"
                case .terminal: "\n[terminal]\n"
                }
                try writeModel(Data(label.utf8))
                lastModelStream = stream
            }
            if modelBytes < modelByteLimit {
                try writeModel(redacted(ready))
            } else {
                // stream 标签本身也计入预算，可能已经占满最后的可用字节。
                didTruncate = true
            }
        } catch {
            writeError = writeError ?? error
        }
    }

    private func redacted(_ data: Data) -> Data {
        guard privacyEnabled else { return data }
        var result = data
        for pattern in patterns where !pattern.value.isEmpty {
            let ranges = result.ranges(of: pattern.value)
            if !ranges.isEmpty { didRedact = true }
            for range in ranges.reversed() {
                result.replaceSubrange(range, with: pattern.replacement)
            }
        }
        return result
    }

    private func writeModel(_ data: Data, ignoresLimit: Bool = false) throws {
        guard !data.isEmpty else { return }
        if ignoresLimit {
            try modelHandle.write(contentsOf: data)
            return
        }
        guard modelBytes < modelByteLimit else {
            didTruncate = true
            return
        }
        let remaining = modelByteLimit - modelBytes
        let slice = data.prefix(Int(min(UInt64(data.count), remaining)))
        try modelHandle.write(contentsOf: slice)
        modelBytes += UInt64(slice.count)
        if slice.count < data.count { didTruncate = true }
    }
}

private extension Data {
    func ranges(of pattern: Data) -> [Range<Int>] {
        guard !pattern.isEmpty, count >= pattern.count else { return [] }
        var ranges: [Range<Int>] = []
        var cursor = startIndex
        while cursor <= endIndex - pattern.count,
              let range = self[cursor...].range(of: pattern) {
            ranges.append(range)
            cursor = range.upperBound
        }
        return ranges
    }
}
