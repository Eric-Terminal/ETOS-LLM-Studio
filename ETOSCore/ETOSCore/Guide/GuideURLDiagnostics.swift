import Foundation

public struct GuideURLDiagnostics: Equatable, Sendable {
    public enum Issue: Equatable, Sendable {
        case trimmed, missingScheme, invalidAddress, embeddedCredentials, endpointRemoved

        func explanation(locale: Locale? = nil) -> String {
            let chinese: String
            let english: String
            switch self {
            case .trimmed:
                chinese = "已去掉地址两端多余的空格或引号。"
                english = "Extra spaces or quotation marks were removed."
            case .missingScheme:
                chinese = "地址开头少了 https:// 或 http://，请按提供商给的地址补上。"
                english = "Add https:// or http:// at the start of the address."
            case .invalidAddress:
                chinese = "请填写完整的基础地址，里面要有服务器的域名或 IP。"
                english = "Enter the base address, including the server name."
            case .embeddedCredentials:
                chinese = "请使用不含密码或密钥的地址，把 API Key 填在专门的密钥栏里。"
                english = "Use an address without credentials. Enter the API key in the key field."
            case .endpointRemoved:
                chinese = "软件会自己加上接口路径，基础地址用这里缩短后的版本就好。"
                english = "The app adds the endpoint itself. Use the shorter base address shown here."
            }
            return GuideAssistantText.localized(chinese, value: english, locale: locale)
        }
    }

    public let normalizedBaseURL: String?
    public let issue: Issue?

    public func explanation(locale: Locale? = nil) -> String? { issue?.explanation(locale: locale) }

    public static func diagnose(_ input: String) -> Self {
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’「」『』"))
        let text = input.trimmingCharacters(in: edges)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else {
            return Self(normalizedBaseURL: nil, issue: .invalidAddress)
        }
        guard text.contains("://") else { return Self(normalizedBaseURL: nil, issue: .missingScheme) }
        guard var url = URLComponents(string: text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return Self(normalizedBaseURL: nil, issue: .invalidAddress) }
        let sensitiveQuery = url.queryItems?.contains { item in
            let name = item.name.lowercased()
            return ["key", "apikey", "api-key", "api_key", "authorization", "signature"].contains(name)
                || name.contains("token") || name.contains("password") || name.contains("secret")
        } ?? false
        guard url.user == nil, url.password == nil, !sensitiveQuery else {
            return Self(normalizedBaseURL: nil, issue: .embeddedCredentials)
        }

        var path = url.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if let suffix = ["/chat/completions", "/responses", "/messages"].first(where: { path.hasSuffix($0) }) {
            path.removeLast(suffix.count)
        } else if let suffix = [":generateContent", ":streamGenerateContent"].first(where: { path.hasSuffix($0) }) {
            path.removeLast(suffix.count)
            // 适配器会自行拼回 models/<模型名> 和调用方法；保留版本段及反代前缀。
            if let models = path.range(of: "/models/", options: .backwards),
               !path[models.upperBound...].contains("/") {
                path = String(path[..<models.lowerBound])
            }
            if suffix == ":streamGenerateContent", let items = url.queryItems {
                let kept = items.filter { $0.name != "alt" || $0.value != "sse" }
                if kept.count != items.count { url.queryItems = kept.isEmpty ? nil : kept }
            }
        } else {
            return Self(normalizedBaseURL: text, issue: text == input ? nil : .trimmed)
        }
        url.percentEncodedPath = path
        return Self(normalizedBaseURL: url.string, issue: .endpointRemoved)
    }

    /// 预览与确认执行必须收到同一地址。仅改写当前页面已声明的远端提供商工具。
    static func normalizedProposalCall(_ call: InternalToolCall) throws -> InternalToolCall {
        var arguments = try GuideToolArguments.decode(call.arguments)
        guard let input = try GuideToolArguments.optionalString("base_url", in: arguments) else { return call }
        let report = diagnose(input)
        guard let url = report.normalizedBaseURL else {
            throw DiagnosticError(message: (report.issue ?? .invalidAddress).explanation())
        }
        guard input != url else { return call }
        arguments["base_url"] = .string(url)
        return InternalToolCall(id: call.id, toolName: call.toolName,
                                arguments: GuideToolArguments.encodedResult(.dictionary(arguments)),
                                providerSpecificFields: call.providerSpecificFields)
    }

    private struct DiagnosticError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
