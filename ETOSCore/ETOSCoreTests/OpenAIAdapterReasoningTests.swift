import Foundation
import Testing
@testable import ETOSCore

struct OpenAIAdapterReasoningTests {
    @Test("普通与流式响应兼容思考字段别名并保持优先级", arguments: [
        (fieldsJSON: #"{"reasoning_content":"原有思考"}"#, expected: "原有思考" as String?),
        (fieldsJSON: #"{"reasoning":"兼容思考"}"#, expected: "兼容思考"),
        (fieldsJSON: #"{"reasoning_content":"原有思考","reasoning":"兼容思考"}"#, expected: "原有思考"),
        (fieldsJSON: #"{"reasoning_content":null,"reasoning":"兼容思考"}"#, expected: "兼容思考"),
        (fieldsJSON: #"{"reasoning_content":"","reasoning":"兼容思考"}"#, expected: "兼容思考"),
        (fieldsJSON: #"{"reasoning_content":""}"#, expected: ""),
        (fieldsJSON: #"{"reasoning":"  保留缩进\n换行  "}"#, expected: "  保留缩进\n换行  "),
        (fieldsJSON: #"{"reasoning_content":null,"reasoning":null}"#, expected: nil),
        (fieldsJSON: "{}", expected: nil)
    ], [false, true])
    func parseReasoningFields(sample: (fieldsJSON: String, expected: String?), isStreaming: Bool) throws {
        let adapter = OpenAIAdapter()
        var message = try #require(JSONSerialization.jsonObject(with: Data(sample.fieldsJSON.utf8)) as? [String: Any])
        message["role"] = "assistant"
        message["content"] = "最终答案"
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [[isStreaming ? "delta" : "message": message]]
        ])

        if isStreaming {
            let part = try #require(adapter.parseStreamingResponse(line: "data: " + String(decoding: data, as: UTF8.self)))
            #expect(part.reasoningContent == sample.expected)
            #expect(part.content == "最终答案")
        } else {
            let response = try adapter.parseResponse(data: data)
            #expect(response.reasoningContent == sample.expected)
            #expect(response.content == "最终答案")
        }
    }

    @Test("reasoning 流式分片保留空白与正文边界")
    func streamingReasoningPreservesDeltaBoundaries() throws {
        let adapter = OpenAIAdapter()
        let lines = [
            #"data: {"choices":[{"delta":{"reasoning":"先分析"}}]}"#,
            #"data: {"choices":[{"delta":{"reasoning":" "}}]}"#,
            #"data: {"choices":[{"delta":{"reasoning":"条件\n"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"最终答案"},"finish_reason":"stop"}]}"#
        ]
        var reasoning = ""
        var content = ""

        for line in lines {
            let part = try #require(adapter.parseStreamingResponse(line: line))
            reasoning += part.reasoningContent ?? ""
            content += part.content ?? ""
        }

        #expect(reasoning == "先分析 条件\n")
        #expect(content == "最终答案")
    }
}
