import ETOSCore
import Foundation

enum MacMCPReadTarget: Hashable, Sendable {
    case resource(MCPResourceDescription)
    case template(MCPResourceTemplate)
    case prompt(MCPPromptDescription)

    var isPrompt: Bool { if case .prompt = self { true } else { false } }
    var isTemplate: Bool { if case .template = self { true } else { false } }
    var name: String {
        switch self {
        case .resource(let resource): resource.resourceId
        case .template(let template): template.title ?? template.name ?? template.uriTemplate
        case .prompt(let prompt): prompt.name
        }
    }
    var description: String {
        switch self {
        case .resource(let resource): resource.description ?? ""
        case .template(let template): template.description ?? ""
        case .prompt(let prompt): prompt.description ?? ""
        }
    }
    var resourceID: String {
        switch self {
        case .resource(let resource): resource.resourceId
        case .template(let template): template.uriTemplate
        case .prompt: ""
        }
    }

    func prepare() throws -> (schema: String, parameters: String) {
        switch self {
        case .resource(let resource):
            return (resource.querySchema?.prettyPrinted() ?? "", "{}")
        case .template:
            return ("", "{}")
        case .prompt(let prompt):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var parameters: [String: JSONValue] = [:]
            for argument in prompt.arguments ?? [] where argument.required == true { parameters[argument.name] = .string("") }
            return (String(decoding: try encoder.encode(prompt.arguments ?? []), as: UTF8.self), JSONValue.dictionary(parameters).prettyPrinted())
        }
    }

    func request(parameters: String, resourceID: String) throws -> MacMCPReadRequest {
        let text = parameters.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded: JSONValue
        if text.isEmpty { decoded = .dictionary([:]) }
        else { decoded = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        guard case .dictionary(let values) = decoded else { throw MacMCPReadError.objectRequired }
        if case .prompt(let prompt) = self {
            var strings: [String: String] = [:]
            for (name, value) in values {
                guard case .string(let text) = value else { throw MacMCPReadError.stringRequired(name) }
                strings[name] = text
            }
            for argument in prompt.arguments ?? [] where argument.required == true && strings[argument.name] == nil {
                throw MacMCPReadError.missingArgument(argument.name)
            }
            return .prompt(name: prompt.name, arguments: strings)
        }
        // 模板仅展示服务端原文，由用户填写完整 URI；不做不完整的 URI 模板展开。
        let uri = isTemplate ? resourceID.trimmingCharacters(in: .whitespacesAndNewlines) : self.resourceID
        if isTemplate, uri.isEmpty || uri.contains("{") || uri.contains("}") { throw MacMCPReadError.concreteURIRequired }
        return .resource(uri: uri, query: values)
    }
}

enum MacMCPReadRequest: Equatable, Sendable {
    case resource(uri: String, query: [String: JSONValue])
    case prompt(name: String, arguments: [String: String])
}

enum MacMCPReadError: LocalizedError {
    case objectRequired, concreteURIRequired
    case stringRequired(String), missingArgument(String)
    var errorDescription: String? {
        switch self {
        case .objectRequired: NSLocalizedString("顶层必须是 JSON 对象（例如 {\"a\": 1}）", comment: "")
        case .concreteURIRequired: NSLocalizedString("请填写已替换模板变量的完整资源 URI。", comment: "")
        case .stringRequired(let name): String(format: NSLocalizedString("提示词参数 %@ 必须是字符串。", comment: ""), name)
        case .missingArgument(let name): String(format: NSLocalizedString("请提供必填参数：%@", comment: ""), name)
        }
    }
}
