// ============================================================================
// ChatServiceStreamingErrorParsing.swift
// ============================================================================
// ETOS LLM Studio
//
// 收敛未解析的流式错误体与 HTTP 状态推断，避免响应编排文件继续超千行。
// ============================================================================

import Foundation

extension ChatService {
    func updateTrailingUnparsedStreamingResponse(
        with line: String,
        body: inout String,
        httpStatusCode: inout Int?
    ) {
        switch classifyUnparsedStreamingLine(line, isCapturingBody: !body.isEmpty) {
        case .append(let payload):
            appendUnparsedStreamingPayload(payload, to: &body)
            if httpStatusCode == nil {
                httpStatusCode = inferredHTTPStatusCode(from: body)
            }
        case .reset:
            body = ""
            httpStatusCode = nil
        case .ignore:
            break
        }
    }

    func makeUnparsedStreamingResponseError(
        body: String,
        fallbackHTTPStatusCode: Int?
    ) -> (body: String, httpStatusCode: Int?)? {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty, looksLikeStreamingErrorResponse(trimmedBody) else {
            return nil
        }
        return (trimmedBody, fallbackHTTPStatusCode ?? inferredHTTPStatusCode(from: trimmedBody))
    }

    private enum UnparsedStreamingLineAction {
        case append(String)
        case reset
        case ignore
    }

    private func classifyUnparsedStreamingLine(
        _ line: String,
        isCapturingBody: Bool
    ) -> UnparsedStreamingLineAction {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else {
            return isCapturingBody ? .append("") : .ignore
        }
        if trimmedLine == "[DONE]" {
            return .reset
        }
        if trimmedLine.hasPrefix("data:") {
            let payload = String(trimmedLine.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" {
                return .reset
            }
            guard !payload.isEmpty else { return .ignore }
            return looksLikeStreamingErrorResponse(payload) || isCapturingBody ? .append(payload) : .ignore
        }
        if trimmedLine.hasPrefix(":")
            || trimmedLine.hasPrefix("event:")
            || trimmedLine.hasPrefix("id:")
            || trimmedLine.hasPrefix("retry:") {
            return .ignore
        }
        return looksLikeStreamingErrorResponse(trimmedLine) || isCapturingBody ? .append(line) : .ignore
    }

    private func appendUnparsedStreamingPayload(_ payload: String, to body: inout String) {
        let maximumLength = 64 * 1024
        if body.isEmpty {
            body = payload
        } else if payload.isEmpty {
            body += "\n"
        } else {
            body += "\n\(payload)"
        }
        if body.count > maximumLength {
            body = String(body.suffix(maximumLength))
        }
    }

    private func looksLikeStreamingErrorResponse(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
           jsonPayloadLooksLikeError(json) {
            return true
        }
        let lowercased = trimmed.lowercased()
        if trimmed.hasPrefix("HTTP/") || trimmed.hasPrefix("<!DOCTYPE") || lowercased.hasPrefix("<html") {
            return true
        }
        let errorMarkers = [
            "bad gateway", "gateway timeout", "gateway time-out", "service unavailable",
            "internal server error", "upstream timed out", "nginx", "cloudflare", "error",
            "错误", "失败", "无法解析流式响应", "无法解析流失响应"
        ]
        return errorMarkers.contains { lowercased.contains($0) }
    }

    private func jsonPayloadLooksLikeError(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let type = dictionary["type"] as? String, type.lowercased() == "error" {
                return true
            }
            if let errorValue = dictionary["error"], !(errorValue is NSNull) {
                return true
            }
            if let statusCode = httpStatusCode(fromJSONObject: dictionary), statusCode >= 400 {
                return true
            }
            return dictionary.values.contains { jsonPayloadLooksLikeError($0) }
        }
        if let array = value as? [Any] {
            return array.contains { jsonPayloadLooksLikeError($0) }
        }
        return false
    }

    private func inferredHTTPStatusCode(from text: String) -> Int? {
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
           let code = httpStatusCode(fromJSONObject: json) {
            return code
        }
        let patterns = [
            #"HTTP/\d(?:\.\d)?\s+([1-5]\d{2})"#,
            #"\b([1-5]\d{2})\s+(?:Bad Gateway|Gateway Timeout|Gateway Time-out|Service Unavailable|Internal Server Error|Not Found|Forbidden|Unauthorized|Too Many Requests)\b"#
        ]
        for pattern in patterns {
            if let code = firstHTTPStatusCode(in: text, pattern: pattern) {
                return code
            }
        }
        let lowercased = text.lowercased()
        if lowercased.contains("gateway timeout") || lowercased.contains("gateway time-out") { return 504 }
        if lowercased.contains("bad gateway") { return 502 }
        if lowercased.contains("service unavailable") { return 503 }
        if lowercased.contains("internal server error") { return 500 }
        if lowercased.contains("too many requests") { return 429 }
        if lowercased.contains("unauthorized") { return 401 }
        if lowercased.contains("forbidden") { return 403 }
        if lowercased.contains("not found") { return 404 }
        return nil
    }

    private func httpStatusCode(fromJSONObject value: Any) -> Int? {
        if let dictionary = value as? [String: Any] {
            for key in ["status", "status_code", "statusCode", "code"] {
                if let code = normalizedHTTPStatusCode(from: dictionary[key]) {
                    return code
                }
            }
            for key in ["error", "response"] {
                if let nested = dictionary[key], let code = httpStatusCode(fromJSONObject: nested) {
                    return code
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let code = httpStatusCode(fromJSONObject: item) {
                    return code
                }
            }
        }
        return nil
    }

    private func normalizedHTTPStatusCode(from value: Any?) -> Int? {
        if let intValue = value as? Int, (100...599).contains(intValue) {
            return intValue
        }
        if let stringValue = value as? String,
           let intValue = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
           (100...599).contains(intValue) {
            return intValue
        }
        return nil
    }

    private func firstHTTPStatusCode(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let codeRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[codeRange])
    }
}
