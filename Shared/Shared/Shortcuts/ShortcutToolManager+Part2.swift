import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

extension ShortcutToolManager {
    func buildRunShortcutURL(
        targetShortcutName: String,
        payloadText: String,
        requestID: String,
        transport: ShortcutExecutionTransport
    ) -> URL? {
        var callbackComponents = URLComponents()
        callbackComponents.scheme = ShortcutURLRouter.appScheme
        callbackComponents.host = "shortcuts"
        callbackComponents.path = "/callback"

        var successComponents = callbackComponents
        successComponents.queryItems = [
            URLQueryItem(name: "request_id", value: requestID),
            URLQueryItem(name: "status", value: "success"),
            URLQueryItem(name: "transport", value: transport.rawValue)
        ]

        var errorComponents = callbackComponents
        errorComponents.queryItems = [
            URLQueryItem(name: "request_id", value: requestID),
            URLQueryItem(name: "status", value: "error"),
            URLQueryItem(name: "transport", value: transport.rawValue)
        ]

        guard let successURL = successComponents.url?.absoluteString,
              let errorURL = errorComponents.url?.absoluteString else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: targetShortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: payloadText),
            URLQueryItem(name: "x-success", value: successURL),
            URLQueryItem(name: "x-error", value: errorURL)
        ]
        return components.url
    }

    func buildOfficialImportRunShortcutURL() -> URL? {
        var successComponents = URLComponents()
        successComponents.scheme = ShortcutURLRouter.appScheme
        successComponents.host = "shortcuts"
        successComponents.path = "/import"
        successComponents.queryItems = [
            URLQueryItem(name: "source", value: "clipboard"),
            URLQueryItem(name: "from", value: "official_template")
        ]

        var errorComponents = URLComponents()
        errorComponents.scheme = ShortcutURLRouter.appScheme
        errorComponents.host = "shortcuts"
        errorComponents.path = "/template-status"
        errorComponents.queryItems = [
            URLQueryItem(name: "status", value: "error"),
            URLQueryItem(name: "stage", value: "run")
        ]

        guard let successURL = successComponents.url?.absoluteString,
              let errorURL = errorComponents.url?.absoluteString else {
            return nil
        }

        let payload: [String: JSONValue] = [
            "source_app": .string("ETOS LLM Studio"),
            "action": .string("official_import"),
            "requested_at": .string(ISO8601DateFormatter().string(from: Date()))
        ]

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: officialImportShortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: JSONValue.dictionary(payload).prettyPrintedCompact()),
            URLQueryItem(name: "x-success", value: successURL),
            URLQueryItem(name: "x-error", value: errorURL)
        ]
        return components.url
    }

    func bridgePayload(for tool: ShortcutToolDefinition, argumentsJSON: String, requestID: String) -> String {
        var payload: [String: JSONValue] = [
            "request_id": .string(requestID),
            "target_shortcut": .string(tool.name),
            "arguments_raw": .string(argumentsJSON),
            "source_app": .string("ETOS LLM Studio")
        ]

        if let decoded = try? decodeJSONDictionary(from: argumentsJSON), !decoded.isEmpty {
            payload["arguments"] = .dictionary(decoded)
        }

        if !tool.metadata.isEmpty {
            payload["tool_metadata"] = .dictionary(tool.metadata)
        }

        return JSONValue.dictionary(payload).prettyPrintedCompact()
    }

    func normalizedArgumentsPayload(from argumentsJSON: String) -> String {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "{}"
        }
        return trimmed
    }

    func formatResultText(_ text: String?) -> String {
        guard let text else { return "" }
        guard let data = text.data(using: .utf8) else { return text }

        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return value.prettyPrintedCompact()
        }
        return text
    }

    func decodeJSONDictionary(from text: String) throws -> [String: JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let data = Data(trimmed.utf8)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    func beginImportProgress() {
        isImporting = true
        isCancellingImport = false
        importCancellationRequested = false
        importProgressCompleted = 0
        importProgressTotal = 0
        importCurrentItemName = nil
    }

    func endImportProgress() {
        isImporting = false
        isCancellingImport = false
        importCancellationRequested = false
        importProgressCompleted = 0
        importProgressTotal = 0
        importCurrentItemName = nil
    }

    func updateImportProgress(currentName: String?, increment: Int) {
        guard !importCancellationRequested else { return }
        if let currentName {
            let trimmed = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
            importCurrentItemName = trimmed.isEmpty ? nil : trimmed
        }
        if increment > 0 {
            importProgressCompleted += increment
            if importProgressTotal > 0 {
                importProgressCompleted = min(importProgressCompleted, importProgressTotal)
            }
        }
    }

    func ensureImportNotCancelled() throws {
        if Task.isCancelled || importCancellationRequested {
            logger.warning("检测到导入取消标记，准备终止当前导入流程。")
            throw CancellationError()
        }
    }

    func decodeImportPayloads(from data: Data) throws -> [ShortcutToolImportPayload] {
        let decoder = JSONDecoder()

        if let manifest = try? decoder.decode(ShortcutToolManifest.self, from: data) {
            guard manifest.schemaVersion == 1 else {
                throw ShortcutToolError.unsupportedSchema(manifest.schemaVersion)
            }
            return manifest.tools
        }

        if let lightManifest = try? decoder.decode(ShortcutLightImportManifest.self, from: data),
           lightManifest.type == .light {
            return lightManifest.data.map { name in
                ShortcutToolImportPayload(
                    name: name,
                    metadata: ["importMode": .string("light")],
                    source: nil,
                    runModeHint: .direct
                )
            }
        }

        if let deepManifest = try? decoder.decode(ShortcutDeepImportManifest.self, from: data),
           deepManifest.type == .deep {
            return deepManifest.data.map { item in
                let link = item.link.trimmingCharacters(in: .whitespacesAndNewlines)
                var metadata: [String: JSONValue] = ["importMode": .string("deep")]
                if !link.isEmpty {
                    metadata["icloudLink"] = .string(link)
                }
                return ShortcutToolImportPayload(
                    name: item.name,
                    metadata: metadata,
                    source: nil,
                    runModeHint: .direct
                )
            }
        }

        throw ShortcutToolError.invalidManifest
    }

    func enrichToolWithDeepScanIfNeeded(_ tool: ShortcutToolDefinition) async -> ShortcutToolDefinition {
        guard tool.metadata["importMode"]?.stringValue == "deep" else {
            return tool
        }
        guard let link = tool.metadata["icloudLink"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !link.isEmpty else {
            return tool
        }

        var next = tool
        var metadata = next.metadata

        if let summary = await fetchShortcutWorkflowSummary(fromICloudLink: link), !summary.isEmpty {
            next.source = summary
            metadata["scanStatus"] = .string("parsed")
            metadata["scanSource"] = .string("icloud_api")
        } else {
            if next.source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                next.source = "iCloud 分享链接：\(link)"
            }
            metadata["scanStatus"] = .string("link_only")
        }

        next.metadata = metadata
        return next
    }

    func fetchShortcutWorkflowSummary(fromICloudLink link: String) async -> String? {
        if importCancellationRequested {
            logger.info("导入已取消，跳过 iCloud 深度解析。")
            return nil
        }
        guard let shortcutID = parseShortcutID(fromICloudLink: link) else { return nil }
        guard let recordURL = URL(string: "https://www.icloud.com/shortcuts/api/records/\(shortcutID)") else {
            return nil
        }

        do {
            var request = URLRequest(url: recordURL)
            request.timeoutInterval = 20
            let (recordData, recordResponse) = try await NetworkSessionConfiguration.shared.data(for: request)
            guard isSuccessStatusCode(recordResponse) else { return nil }
            if importCancellationRequested {
                logger.info("导入已取消，停止后续 iCloud 下载解析。")
                return nil
            }

            let shortcutData = try await extractShortcutDataFromRecordPayload(recordData)
            guard let shortcutData else { return nil }
            return summarizeShortcutPlist(shortcutData)
        } catch {
            logger.warning("深度导入扫描失败: \(error.localizedDescription)")
            return nil
        }
    }

    func parseShortcutID(fromICloudLink link: String) -> String? {
        guard let url = URL(string: link),
              let host = url.host?.lowercased(),
              host.contains("icloud.com") else {
            return nil
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let shortcutsIndex = components.firstIndex(of: "shortcuts"),
              components.indices.contains(shortcutsIndex + 1) else {
            return nil
        }
        let rawID = components[shortcutsIndex + 1]
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func extractShortcutDataFromRecordPayload(_ data: Data) async throws -> Data? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = root["fields"] as? [String: Any] else {
            return nil
        }

        if let encoded = nestedValue(fields, keyPath: ["data", "value"]) as? String,
           let decoded = Data(base64Encoded: encoded) {
            return decoded
        }

        let downloadURLString = (nestedValue(fields, keyPath: ["downloadURL", "value"]) as? String)
            ?? (nestedValue(fields, keyPath: ["downloadUrl", "value"]) as? String)
        guard let downloadURLString,
              let downloadURL = URL(string: downloadURLString) else {
            return nil
        }

        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 20
        let (downloadData, downloadResponse) = try await NetworkSessionConfiguration.shared.data(for: request)
        return isSuccessStatusCode(downloadResponse) ? downloadData : nil
    }

    func nestedValue(_ dictionary: [String: Any], keyPath: [String]) -> Any? {
        var current: Any = dictionary
        for key in keyPath {
            guard let currentDict = current as? [String: Any],
                  let next = currentDict[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    func summarizeShortcutPlist(_ data: Data) -> String? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = object as? [String: Any] else {
            return nil
        }

        let workflowName = (root["WFWorkflowName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = (root["WFWorkflowActions"] as? [[String: Any]]) ?? []
        guard !actions.isEmpty else {
            if let workflowName, !workflowName.isEmpty {
                return "流程名：\(workflowName)。未解析到动作详情。"
            }
            return "未解析到动作详情。"
        }

        var orderedActionNames: [String] = []
        var seen = Set<String>()
        for action in actions {
            guard let identifier = action["WFWorkflowActionIdentifier"] as? String else { continue }
            let normalized = normalizeActionIdentifier(identifier)
            if seen.insert(normalized).inserted {
                orderedActionNames.append(normalized)
            }
        }

        let preview = orderedActionNames.prefix(12).joined(separator: "、")
        var fragments: [String] = []
        if let workflowName, !workflowName.isEmpty {
            fragments.append("流程名：\(workflowName)")
        }
        fragments.append("动作总数：\(actions.count)")
        if !preview.isEmpty {
            fragments.append("关键动作：\(preview)")
        }
        return fragments.joined(separator: "；")
    }

    func normalizeActionIdentifier(_ identifier: String) -> String {
        let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let replaced = tail.replacingOccurrences(of: "_", with: " ")
        return replaced.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isSuccessStatusCode(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - Helpers

    func rebuildRouting() {
        var routes: [String: ShortcutToolDefinition] = [:]
        for tool in tools {
            let alias = ShortcutToolNaming.alias(for: tool)
            routes[alias] = tool
            routes["\(Self.toolNamePrefix)\(tool.id.uuidString)"] = tool
        }
        routedTools = routes
    }

    func persistCurrentTools() {
        tools.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        ShortcutToolStore.saveTools(tools)
        rebuildRouting()
    }

    func makeGeneratedDescription(from payload: ShortcutToolImportPayload) -> String {
        var parts: [String] = []

        if let type = payload.metadata["category"]?.stringValue, !type.isEmpty {
            parts.append(String(format: NSLocalizedString("分类：%@", comment: "Shortcut generated description category sent to model"), type))
        }
        if let capability = payload.metadata["capability"]?.stringValue, !capability.isEmpty {
            parts.append(String(format: NSLocalizedString("能力：%@", comment: "Shortcut generated description capability sent to model"), capability))
        }
        if let source = payload.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
            let brief = source.count > 120 ? String(source.prefix(120)) + "..." : source
            parts.append(String(format: NSLocalizedString("流程摘要：%@", comment: "Shortcut generated description source sent to model"), brief))
        }

        if parts.isEmpty {
            return String(format: NSLocalizedString("执行快捷指令 %@，用于完成自动化任务。", comment: "Shortcut generated description fallback sent to model"), payload.name)
        }
        let separator = NSLocalizedString("；", comment: "Shortcut generated description separator sent to model")
        return String(
            format: NSLocalizedString("执行快捷指令 %@。%@", comment: "Shortcut generated description sent to model"),
            payload.name,
            parts.joined(separator: separator)
        )
    }

    func makeGeneratedDescription(for tool: ShortcutToolDefinition) -> String {
        makeGeneratedDescription(
            from: ShortcutToolImportPayload(
                name: tool.name,
                externalID: tool.externalID,
                metadata: tool.metadata,
                source: tool.source,
                runModeHint: tool.runModeHint
            )
        )
    }

    func queryItem(named name: String, in url: URL?) -> String? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    func parseNestedURLQueryItem(named name: String, in url: URL?) -> URL? {
        guard let value = queryItem(named: name, in: url) else { return nil }
        return URL(string: value)
    }

    func notifyImportCallback(
        summary: ShortcutImportSummary,
        triggerURL: URL?,
        success: Bool,
        errorMessage: String?
    ) async {
        guard let callbackURL = parseNestedURLQueryItem(named: success ? "x_success" : "x_error", in: triggerURL) else {
            return
        }

        guard var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            return
        }

        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "imported", value: "\(summary.importedCount)"))
        query.append(URLQueryItem(name: "skipped", value: "\(summary.skippedCount)"))
        query.append(URLQueryItem(name: "invalid", value: "\(summary.invalidCount)"))
        if !summary.conflictNames.isEmpty {
            query.append(URLQueryItem(name: "conflicts", value: summary.conflictNames.joined(separator: ",")))
        }
        if let errorMessage, !errorMessage.isEmpty {
            query.append(URLQueryItem(name: "error", value: errorMessage))
        }
        components.queryItems = query

        guard let finalURL = components.url else { return }
        _ = await openSystemURL(finalURL)
    }

    func clipboardText() -> String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #else
        return nil
        #endif
    }

    func openSystemURL(_ url: URL) async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
        #elseif os(watchOS)
        WKExtension.shared().openSystemURL(url)
        return true
        #else
        return false
        #endif
    }
}
