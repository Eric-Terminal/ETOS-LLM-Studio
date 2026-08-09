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
    private let rawHandle: FileHandle
    private let modelHandle: FileHandle
    private let patterns: [RedactionPattern]
    private let privacyEnabled: Bool
    private let modelByteLimit: UInt64

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
    private var lastUserPreviewStream: LocalLinuxOutputStream?
    private let userPreviewLimit = 262_144
    private var terminalScreen: LocalLinuxTerminalScreen?

    public init(
        rawURL: URL,
        modelURL: URL,
        redactionValues: [String],
        privacyEnabled: Bool,
        modelByteLimit: UInt64,
        terminalColumns: Int? = nil,
        terminalRows: Int? = nil
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
        self.modelByteLimit = modelByteLimit
        if let terminalColumns, let terminalRows {
            terminalScreen = LocalLinuxTerminalScreen(
                columns: terminalColumns,
                rows: terminalRows
            )
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

    public func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
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
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: userPreview, as: UTF8.self)
    }

    public func resizeTerminalPreview(columns: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
        terminalScreen?.resize(columns: columns, rows: rows)
        replaceUserPreviewWithTerminalSnapshot()
    }

    private func writeRawFrame(stream: LocalLinuxOutputStream, data: Data) throws {
        let marker: UInt8
        switch stream {
        case .stdout: marker = 1
        case .stderr: marker = 2
        case .terminal: marker = 3
        }
        var length = UInt32(data.count).bigEndian
        var header = Data([marker])
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        try rawHandle.write(contentsOf: header)
        try rawHandle.write(contentsOf: data)
    }

    private func appendUserPreview(stream: LocalLinuxOutputStream, data: Data) {
        if stream == .terminal, let terminalScreen {
            terminalScreen.append(data)
            replaceUserPreviewWithTerminalSnapshot()
            lastUserPreviewStream = stream
            return
        }
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

    private func replaceUserPreviewWithTerminalSnapshot() {
        guard let terminalScreen else { return }
        userPreview = Data(terminalScreen.renderedText().utf8)
        if userPreview.count > userPreviewLimit {
            userPreview.removeFirst(userPreview.count - userPreviewLimit)
        }
    }

    private func appendModelBytes(stream: LocalLinuxOutputStream, data: Data, flush: Bool) {
        var combined = pendingByStream[stream, default: Data()]
        combined.append(data)
        let maximumPatternBytes = privacyEnabled ? patterns.map(\.value.count).max() ?? 0 : 0
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
            try writeModel(redacted(ready))
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
