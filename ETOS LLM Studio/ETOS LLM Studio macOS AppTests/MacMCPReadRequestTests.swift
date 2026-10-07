import ETOSCore
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacMCPReadRequestTests {
    @Test("资源读取保留查询值类型和固定来源 URI，拒绝非对象参数")
    func resourceQuery() throws {
        let target = MacMCPReadTarget.resource(MCPResourceDescription(resourceId: "file:///original", description: nil, outputSchema: nil, querySchema: nil))
        #expect(try target.request(parameters: #"{"limit":2,"enabled":true}"#, resourceID: "file:///other") ==
                .resource(uri: "file:///original", query: ["limit": .int(2), "enabled": .bool(true)]))
        #expect(try target.request(parameters: " \n", resourceID: "") == .resource(uri: "file:///original", query: [:]))
        #expect(throws: MacMCPReadError.self) { try target.request(parameters: "[]", resourceID: "") }
    }

    @Test("提示词保留字符串内容并校验必填项，不隐式转换数字或数组")
    func promptArguments() throws {
        let prompt = MCPPromptDescription(name: "review", description: nil, arguments: [
            MCPPromptArgument(name: "source", description: nil, required: true),
            MCPPromptArgument(name: "style", description: nil, required: false)
        ])
        let target = MacMCPReadTarget.prompt(prompt)
        #expect(try target.request(parameters: #"{"source":" a\n b ","style":"brief"}"#, resourceID: "") ==
                .prompt(name: "review", arguments: ["source": " a\n b ", "style": "brief"]))
        #expect(throws: MacMCPReadError.self) { try target.request(parameters: "{}", resourceID: "") }
        #expect(throws: MacMCPReadError.self) { try target.request(parameters: #"{"source":2}"#, resourceID: "") }
        #expect(throws: MacMCPReadError.self) { try target.request(parameters: #"{"source":[]}"#, resourceID: "") }
    }

    @Test("资源模板需要完整 URI，保留已编码字符而不重复转义")
    func resourceTemplate() throws {
        let target = MacMCPReadTarget.template(MCPResourceTemplate(uriTemplate: "repo://{name}/file", name: nil, title: nil,
                                                                  description: nil, mimeType: nil, annotations: nil))
        #expect(throws: MacMCPReadError.self) { try target.request(parameters: "{}", resourceID: "repo://{name}/file") }
        #expect(throws: MacMCPReadError.self) { try target.request(parameters: "{}", resourceID: " \n") }
        #expect(try target.request(parameters: "{}", resourceID: " repo://a%20b/file ") == .resource(uri: "repo://a%20b/file", query: [:]))
    }

    @Test("参数草稿只预填必填名，重复服务端声明不会导致崩溃")
    func preparesRequiredArgumentDraft() throws {
        let target = MacMCPReadTarget.prompt(MCPPromptDescription(name: "prompt", description: nil, arguments: [
            MCPPromptArgument(name: "required", description: nil, required: true),
            MCPPromptArgument(name: "required", description: nil, required: true),
            MCPPromptArgument(name: "optional", description: nil, required: false)
        ]))
        let prepared = try target.prepare()
        #expect(try target.request(parameters: prepared.parameters, resourceID: "") == .prompt(name: "prompt", arguments: ["required": ""]))
        #expect(prepared.schema.contains("optional"))
    }
}
