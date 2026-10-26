import Foundation

enum GeminiVideoRequestRebinding {
    /// 仅替换 Gemini 文件引用，保留中断续写生成的正文和工具参数。
    static func replacingFileReferences(
        in request: URLRequest,
        previous: [UUID: [FileAttachment]],
        updated: [UUID: [FileAttachment]]
    ) throws -> URLRequest {
        var replacements: [String: String] = [:]
        for (messageID, attachments) in previous {
            for (old, new) in zip(attachments, updated[messageID] ?? []) {
                if let oldURI = old.remoteFileURI, let newURI = new.remoteFileURI {
                    replacements[oldURI] = newURI
                }
            }
        }
        guard let data = request.httpBody,
              var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiVideoUploadError.invalidResponse
        }
        if var input = payload["input"] as? [[String: Any]] {
            for index in input.indices {
                guard var content = input[index]["content"] as? [[String: Any]] else { continue }
                for contentIndex in content.indices where content[contentIndex]["type"] as? String == "video" {
                    if let uri = content[contentIndex]["uri"] as? String, let replacement = replacements[uri] {
                        content[contentIndex]["uri"] = replacement
                    }
                }
                input[index]["content"] = content
            }
            payload["input"] = input
            var result = request
            result.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return result
        }
        guard var contents = payload["contents"] as? [[String: Any]] else { throw GeminiVideoUploadError.invalidResponse }
        for contentIndex in contents.indices {
            guard var parts = contents[contentIndex]["parts"] as? [[String: Any]] else { continue }
            for partIndex in parts.indices {
                guard var file = parts[partIndex]["file_data"] as? [String: Any],
                      let uri = file["file_uri"] as? String,
                      let replacement = replacements[uri] else { continue }
                file["file_uri"] = replacement
                parts[partIndex]["file_data"] = file
            }
            contents[contentIndex]["parts"] = parts
        }
        payload["contents"] = contents
        var result = request
        result.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return result
    }
}
