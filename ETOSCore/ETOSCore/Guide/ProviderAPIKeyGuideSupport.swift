import Foundation

public enum ProviderAPIKeyGuideSupport {
    public static func validate(_ arguments: [String: JSONValue]) throws {
        if let value = arguments["multi_key_enabled"] {
            guard case .bool = value else { throw GuideError.invalidToolArguments }
        }
        if let value = arguments["maximum_key_retries"] {
            guard case .int(let count) = value, ProviderAPIKeyRetryPolicy.allowedMaximumRetries.contains(count) else {
                throw GuideError.invalidToolArguments
            }
        }
    }

    @MainActor
    public static func apply(_ arguments: [String: JSONValue], to editor: ProviderAPIKeyEditorModel) throws {
        try validate(arguments)
        if case .bool(let enabled)? = arguments["multi_key_enabled"] { editor.draft.multiKeyEnabled = enabled }
        if case .int(let count)? = arguments["maximum_key_retries"] { editor.draft.maximumRetriesText = String(count) }
    }
}
