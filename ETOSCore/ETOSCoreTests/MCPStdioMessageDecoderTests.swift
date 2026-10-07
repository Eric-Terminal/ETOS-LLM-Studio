// ============================================================================
// MCPStdioMessageDecoderTests.swift
// ============================================================================
// 验证管道分片、UTF-8、输出污染和边界限制，不依赖外部 MCP 服务。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("MCP stdio 消息边界")
struct MCPStdioMessageDecoderTests {
    @Test("任意分片位置均保留多字节文本和连续帧")
    func fragmentedUnicodeMessages() throws {
        let first = Data(#"{"jsonrpc":"2.0","id":1,"result":{"text":"你好，🌙"}}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8)
        var wire = first
        wire.append(contentsOf: [0x0D, 0x0A])
        wire.append(second)
        wire.append(0x0A)
        for split in 0...wire.count {
            var decoder = MCPStdioMessageDecoder()
            let prefix = try decoder.append(Data(wire.prefix(split)))
            let suffix = try decoder.append(Data(wire.dropFirst(split)))
            #expect(prefix + suffix == [first, second])
            try decoder.finish()
        }
    }

    @Test("普通日志、无版本 JSON、空行和非法 UTF-8 不能作为协议响应")
    func rejectsPollutedOutput() {
        for data in [Data("ready\n".utf8), Data("{}\n".utf8), Data([0x0A]), Data([0xFF, 0x0A])] {
            var decoder = MCPStdioMessageDecoder()
            #expect(throws: MCPLocalStdioError.self) { try decoder.append(data) }
        }
    }

    @Test("进程退出时不把截断响应伪装成完整消息")
    func rejectsTruncatedOutput() throws {
        var decoder = MCPStdioMessageDecoder()
        #expect(try decoder.append(Data(#"{"jsonrpc":"2.0","id":1"#.utf8)).isEmpty)
        #expect(throws: MCPLocalStdioError.self) { try decoder.finish() }
    }

    @Test("超长且未换行的输出受内存边界限制")
    func boundsUnterminatedMessage() {
        var decoder = MCPStdioMessageDecoder()
        let data = Data(repeating: 0x20, count: MCPStdioMessageDecoder.maximumMessageBytes + 1)
        #expect(throws: MCPStdioFramingError.self) { try decoder.append(data) }
    }

    @Test("发送端保证一个 JSON-RPC 对象只占一行")
    func framesOutgoingMessage() throws {
        let message = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        let framed = message + Data([0x0A])
        #expect(try MCPStdioMessageDecoder.frame(message) == framed)
        #expect(try MCPStdioMessageDecoder.frame(framed) == framed)
        #expect(throws: MCPLocalStdioError.self) {
            try MCPStdioMessageDecoder.frame(framed + framed)
        }
    }
}
