// ============================================================================
// MCPStdioMessageDecoder.swift
// ============================================================================
// stdio 的消息边界是换行符，与管道每次返回多少字节无关。限制单帧大小，
// 防止没有换行符的 stdout 无限增长；UTF-8 与 JSON 校验只在完整帧上执行。
// ============================================================================

import Foundation

enum MCPStdioFramingError: LocalizedError {
    case bufferOverflow

    var errorDescription: String? {
        NSLocalizedString(
            "The MCP process exceeded the standard output buffer limit.",
            comment: "MCP stdio output limit exceeded"
        )
    }
}

struct MCPStdioMessageDecoder {
    static let maximumMessageBytes = 32 * 1024 * 1024
    private var pending = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        var messages: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 0x0A)
            let end = newline ?? data.endIndex
            guard pending.count + end - start <= Self.maximumMessageBytes else {
                throw MCPStdioFramingError.bufferOverflow
            }
            pending.append(contentsOf: data[start..<end])
            guard let newline else { break }
            if pending.last == 0x0D { pending.removeLast() }
            try Self.validate(pending)
            messages.append(pending)
            pending = Data()
            start = data.index(after: newline)
        }
        return messages
    }

    func finish() throws {
        guard pending.isEmpty else { throw MCPLocalStdioError.invalidStandardOutput }
    }

    static func frame(_ data: Data) throws -> Data {
        var message = data
        if message.last == 0x0A { message.removeLast() }
        if message.last == 0x0D { message.removeLast() }
        guard !message.contains(0x0A), !message.contains(0x0D) else {
            throw MCPLocalStdioError.invalidStandardOutput
        }
        guard message.count <= maximumMessageBytes else { throw MCPStdioFramingError.bufferOverflow }
        try validate(message)
        message.append(0x0A)
        return message
    }

    private static func validate(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["jsonrpc"] as? String == "2.0" else {
            throw MCPLocalStdioError.invalidStandardOutput
        }
    }
}
