// ============================================================================
// ChatServiceErrorFormatting.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的错误内容格式化与 HTTP 状态描述。
// ============================================================================

import Foundation

extension ChatService {
    func formatErrorContent(_ content: String, httpStatusCode: Int? = nil) -> (String, String?) {
        let maxLength = 500
        var displayMessage: String
        var fullContent: String?

        var statusPrefix = ""
        if let code = httpStatusCode {
            let description = httpStatusCodeDescription(code)
            statusPrefix = String(
                format: NSLocalizedString("HTTP %d: %@\n\n", comment: "HTTP status prefix with code and description"),
                code,
                description
            )
        }

        if content.count > maxLength {
            let truncatedContent = String(content.prefix(maxLength))
            let truncationNotice = NSLocalizedString(
                "...\n\n(响应已截断，可在更多操作中查看完整内容)",
                comment: "Truncation notice for long error content"
            )
            displayMessage = statusPrefix + truncatedContent + truncationNotice
            fullContent = statusPrefix + content
        } else {
            displayMessage = statusPrefix + content
            fullContent = nil
        }

        return (displayMessage, fullContent)
    }

    private func httpStatusCodeDescription(_ code: Int) -> String {
        switch code {
        case 400: return NSLocalizedString("请求格式错误 (Bad Request)", comment: "HTTP 400 description")
        case 401: return NSLocalizedString("未授权，请检查 API Key (Unauthorized)", comment: "HTTP 401 description")
        case 403: return NSLocalizedString("访问被拒绝，权限不足 (Forbidden)", comment: "HTTP 403 description")
        case 404: return NSLocalizedString("请求的资源不存在 (Not Found)", comment: "HTTP 404 description")
        case 405: return NSLocalizedString("请求方法不被允许 (Method Not Allowed)", comment: "HTTP 405 description")
        case 408: return NSLocalizedString("请求超时 (Request Timeout)", comment: "HTTP 408 description")
        case 409: return NSLocalizedString("请求冲突 (Conflict)", comment: "HTTP 409 description")
        case 413: return NSLocalizedString("请求体过大 (Payload Too Large)", comment: "HTTP 413 description")
        case 415: return NSLocalizedString("不支持的媒体类型 (Unsupported Media Type)", comment: "HTTP 415 description")
        case 422: return NSLocalizedString("请求参数无法处理 (Unprocessable Entity)", comment: "HTTP 422 description")
        case 429: return NSLocalizedString("请求过于频繁，请稍后重试 (Too Many Requests)", comment: "HTTP 429 description")
        case 500: return NSLocalizedString("服务器内部错误 (Internal Server Error)", comment: "HTTP 500 description")
        case 501: return NSLocalizedString("功能未实现 (Not Implemented)", comment: "HTTP 501 description")
        case 502: return NSLocalizedString("网关错误，上游服务无响应 (Bad Gateway)", comment: "HTTP 502 description")
        case 503: return NSLocalizedString("服务暂时不可用 (Service Unavailable)", comment: "HTTP 503 description")
        case 504: return NSLocalizedString("网关超时 (Gateway Timeout)", comment: "HTTP 504 description")
        case 520: return NSLocalizedString("未知错误 (Cloudflare)", comment: "HTTP 520 description")
        case 521: return NSLocalizedString("服务器宕机 (Cloudflare)", comment: "HTTP 521 description")
        case 522: return NSLocalizedString("连接超时 (Cloudflare)", comment: "HTTP 522 description")
        case 523: return NSLocalizedString("源站不可达 (Cloudflare)", comment: "HTTP 523 description")
        case 524: return NSLocalizedString("响应超时 (Cloudflare)", comment: "HTTP 524 description")
        case 525: return NSLocalizedString("SSL 握手失败 (Cloudflare)", comment: "HTTP 525 description")
        case 526: return NSLocalizedString("无效的 SSL 证书 (Cloudflare)", comment: "HTTP 526 description")
        default:
            if code >= 400 && code < 500 {
                return NSLocalizedString("客户端错误", comment: "Generic 4xx error description")
            } else if code >= 500 && code < 600 {
                return NSLocalizedString("服务器错误", comment: "Generic 5xx error description")
            }
            return NSLocalizedString("HTTP 错误", comment: "Generic HTTP error description")
        }
    }
}
