// ============================================================================
// AppToolJavaScriptExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地 JavaScript 工具的执行与自定义脚本工具持久化。
// ============================================================================

import Foundation
import Combine
import os.log

#if canImport(JavaScriptCore) && !os(watchOS)
import JavaScriptCore
#endif

#if os(watchOS)
import Darwin
#endif

public enum AppToolCustomJSEngine: String, Codable, Hashable, CaseIterable, Sendable {
    case javaScriptCore = "javascript_core"
    case webKitBridge = "webkit_bridge"

    public var displayName: String {
        switch self {
        case .javaScriptCore:
            return NSLocalizedString("Apple JavaScriptCore", comment: "JavaScriptCore engine display name")
        case .webKitBridge:
            return NSLocalizedString("watchOS WebKit JavaScript bridge", comment: "watchOS WebKit JavaScript bridge engine display name")
        }
    }

    public var isAvailableOnCurrentPlatform: Bool {
        switch self {
        case .javaScriptCore:
            #if canImport(JavaScriptCore) && !os(watchOS)
            return true
            #else
            return false
            #endif
        case .webKitBridge:
            #if os(watchOS)
            return true
            #else
            return false
            #endif
        }
    }
}

public struct AppToolCustomJSTool: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var engine: AppToolCustomJSEngine
    public var displayName: String
    public var toolDescription: String
    public var parameters: JSONValue
    public var isEnabled: Bool
    public var approvalPolicy: AppToolApprovalPolicy
    public var createdAt: Date
    public var updatedAt: Date

    public var toolName: String {
        switch engine {
        case .javaScriptCore:
            return AppToolManager.customJSCJSToolNamePrefix + id
        case .webKitBridge:
            return AppToolManager.customWebKitJSToolNamePrefix + id
        }
    }
}

extension AppToolManager {
    nonisolated public static let customJSCJSToolNamePrefix = "app_custom_jsc_"
    nonisolated public static let customWebKitJSToolNamePrefix = "app_custom_webkit_js_"

    struct CustomJSToolIdentity: Hashable, Sendable {
        let engine: AppToolCustomJSEngine
        let id: String
    }

    nonisolated public static func isCustomJSToolName(_ name: String) -> Bool {
        name.hasPrefix(customJSCJSToolNamePrefix) || name.hasPrefix(customWebKitJSToolNamePrefix)
    }

    nonisolated static func customJSToolIdentity(from toolName: String) -> CustomJSToolIdentity? {
        if toolName.hasPrefix(customJSCJSToolNamePrefix) {
            let id = String(toolName.dropFirst(customJSCJSToolNamePrefix.count))
            return id.isEmpty ? nil : CustomJSToolIdentity(engine: .javaScriptCore, id: id)
        }
        if toolName.hasPrefix(customWebKitJSToolNamePrefix) {
            let id = String(toolName.dropFirst(customWebKitJSToolNamePrefix.count))
            return id.isEmpty ? nil : CustomJSToolIdentity(engine: .webKitBridge, id: id)
        }
        return nil
    }

    public func customJSTool(withID id: String, engine: AppToolCustomJSEngine) -> AppToolCustomJSTool? {
        customJSTools.first(where: { $0.id == id && $0.engine == engine })
    }

    public func customJSTool(withToolName toolName: String) -> AppToolCustomJSTool? {
        guard let identity = Self.customJSToolIdentity(from: toolName) else { return nil }
        return customJSTool(withID: identity.id, engine: identity.engine)
    }

    public func isCustomJSToolEnabled(id: String, engine: AppToolCustomJSEngine) -> Bool {
        customJSTool(withID: id, engine: engine)?.isEnabled ?? false
    }

    public func setCustomJSToolEnabled(id: String, engine: AppToolCustomJSEngine, isEnabled: Bool) {
        guard let index = customJSTools.firstIndex(where: { $0.id == id && $0.engine == engine }) else { return }
        customJSTools[index].isEnabled = isEnabled
        customJSTools[index].updatedAt = Date()
        persistCustomJSTool(customJSTools[index])
        objectWillChange.send()
    }

    public func setCustomJSToolApprovalPolicy(id: String, engine: AppToolCustomJSEngine, policy: AppToolApprovalPolicy) {
        guard let index = customJSTools.firstIndex(where: { $0.id == id && $0.engine == engine }) else { return }
        customJSTools[index].approvalPolicy = policy
        customJSTools[index].updatedAt = Date()
        persistCustomJSTool(customJSTools[index])
        objectWillChange.send()
    }

    public func customJSToolScriptURL(id: String, engine: AppToolCustomJSEngine) -> URL {
        Self.customJSToolDirectoryURL(id: id, engine: engine)
            .appendingPathComponent("script.js", isDirectory: false)
    }

    func customJSToolDefinition(for tool: AppToolCustomJSTool) -> InternalToolDefinition {
        let description = String(
            format: NSLocalizedString(
                "自定义 JavaScript 工具。脚本由 AI 创建并保存在应用的 CustomJSTools 独立目录中，执行入口为同步 function main(input)。运行引擎：%@。没有 Node.js、require/import、文件系统、原生网络 API 或持久后台任务能力。工具说明：%@",
                comment: "Custom JS tool description sent to model"
            ),
            tool.engine.displayName,
            tool.toolDescription
        )
        return InternalToolDefinition(
            name: tool.toolName,
            description: ModelPromptLanguage.appendingToolArgumentInstruction(to: description),
            parameters: tool.parameters,
            isBlocking: true
        )
    }

    func executeJavaScript(argumentsJSON: String, engine: AppToolCustomJSEngine) async throws -> String {
        struct ExecuteJavaScriptArgs: Decodable {
            let code: String
            let input: JSONValue?
        }

        let args = try Self.decodeJavaScriptArguments(
            argumentsJSON,
            as: ExecuteJavaScriptArgs.self,
            errorMessage: NSLocalizedString("错误：无法解析 JavaScript 执行参数，请提供 code。", comment: "Execute JavaScript invalid arguments")
        )
        return try await runJavaScript(
            code: args.code,
            input: args.input ?? .null,
            source: .adHoc,
            engine: engine
        )
    }

    func executeCreateCustomJSTool(argumentsJSON: String, engine: AppToolCustomJSEngine) async throws -> String {
        struct CreateCustomJSToolArgs: Decodable {
            let tool_id: String?
            let display_name: String
            let description: String
            let parameters_schema: JSONValue?
            let code: String
            let enabled: Bool?
            let approval_policy: String?
            let overwrite: Bool?
        }

        let args = try Self.decodeJavaScriptArguments(
            argumentsJSON,
            as: CreateCustomJSToolArgs.self,
            errorMessage: NSLocalizedString("错误：无法解析自定义 JavaScript 工具参数，请提供 display_name、description 和 code。", comment: "Create custom JS tool invalid arguments")
        )

        let displayName = args.display_name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = args.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = args.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, !description.isEmpty, !code.isEmpty else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：display_name、description 和 code 都不能为空。", comment: "Create custom JS tool empty fields")
            )
        }
        if let schema = args.parameters_schema {
            guard case .dictionary = schema else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：parameters_schema 必须是 JSON object。", comment: "Create custom JS tool invalid schema")
                )
            }
        }

        let id = try Self.normalizedCustomJSToolID(args.tool_id, fallbackName: displayName)
        let directoryURL = Self.customJSToolDirectoryURL(id: id, engine: engine)
        let manifestURL = directoryURL.appendingPathComponent("manifest.json", isDirectory: false)
        let scriptURL = directoryURL.appendingPathComponent("script.js", isDirectory: false)
        let overwrite = args.overwrite ?? false
        if FileManager.default.fileExists(atPath: manifestURL.path), !overwrite {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：同名自定义 JavaScript 工具已存在，如需覆盖请传 overwrite=true。", comment: "Create custom JS tool duplicate")
            )
        }

        let policy = args.approval_policy
            .flatMap { AppToolApprovalPolicy(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? .askEveryTime
        let now = Date()
        let existing = customJSTool(withID: id, engine: engine)
        let tool = AppToolCustomJSTool(
            id: id,
            engine: engine,
            displayName: displayName,
            toolDescription: description,
            parameters: args.parameters_schema ?? Self.defaultCustomJSToolParametersSchema,
            isEnabled: args.enabled ?? existing?.isEnabled ?? true,
            approvalPolicy: policy,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try code.write(to: scriptURL, atomically: true, encoding: .utf8)
        try Self.writeCustomJSToolManifest(tool, to: manifestURL)

        if let index = customJSTools.firstIndex(where: { $0.id == id && $0.engine == engine }) {
            customJSTools[index] = tool
        } else {
            customJSTools.append(tool)
            customJSTools.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        objectWillChange.send()

        return prettyPrintedJSONString(from: [
            "tool_name": tool.toolName,
            "tool_id": tool.id,
            "display_name": tool.displayName,
            "engine": tool.engine.displayName,
            "enabled": tool.isEnabled,
            "approval_policy": tool.approvalPolicy.rawValue,
            "directory": directoryURL.path
        ])
    }

    func executeCustomJSTool(_ tool: AppToolCustomJSTool, argumentsJSON: String) async throws -> String {
        let input = try Self.decodeJSONValue(
            argumentsJSON,
            errorMessage: NSLocalizedString("错误：无法解析自定义 JavaScript 工具参数。", comment: "Custom JS tool invalid arguments")
        )
        let code = try String(contentsOf: customJSToolScriptURL(id: tool.id, engine: tool.engine), encoding: .utf8)
        return try await runJavaScript(code: code, input: input, source: .custom(toolID: tool.id), engine: tool.engine)
    }

    private enum JavaScriptToolSource {
        case adHoc
        case custom(toolID: String)
    }

    private func runJavaScript(
        code: String,
        input: JSONValue,
        source: JavaScriptToolSource,
        engine: AppToolCustomJSEngine
    ) async throws -> String {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：JavaScript code 不能为空。", comment: "Execute JavaScript empty code")
            )
        }

        let wrappedScript = try Self.makeJavaScriptWrapper(code: trimmedCode, input: input)
        let engineResult = try await Self.executeWrappedJavaScript(wrappedScript, engine: engine)
        var payload: [String: Any] = [
            "engine": engineResult.engine.displayName,
            "result": engineResult.result.toAny(),
            "console": engineResult.console
        ]
        if case .custom(let toolID) = source {
            payload["custom_tool_id"] = toolID
        }
        return prettyPrintedJSONString(from: payload)
    }

    private static func decodeJavaScriptArguments<T: Decodable>(
        _ argumentsJSON: String,
        as type: T.Type,
        errorMessage: String
    ) throws -> T {
        guard let data = argumentsJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw AppToolExecutionError.invalidArguments(errorMessage)
        }
        return value
    }

    private static func decodeJSONValue(_ argumentsJSON: String, errorMessage: String) throws -> JSONValue {
        guard let data = argumentsJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw AppToolExecutionError.invalidArguments(errorMessage)
        }
        return value
    }

    private static func makeJavaScriptWrapper(code: String, input: JSONValue) throws -> String {
        let inputData = try JSONEncoder().encode(input)
        guard let inputJSON = String(data: inputData, encoding: .utf8) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：JavaScript input 不是有效 UTF-8 JSON。", comment: "JavaScript input encoding error")
            )
        }

        return """
        (() => {
          const __etosInput = \(inputJSON);
          const __etosConsole = [];
          function __etosFormat(value) {
            if (typeof value === "string") { return value; }
            if (typeof value === "undefined") { return "undefined"; }
            try { return JSON.stringify(value); } catch (_) { return String(value); }
          }
          globalThis.console = {
            log: (...items) => __etosConsole.push(items.map(__etosFormat).join(" ")),
            info: (...items) => __etosConsole.push(items.map(__etosFormat).join(" ")),
            warn: (...items) => __etosConsole.push(items.map(__etosFormat).join(" ")),
            error: (...items) => __etosConsole.push(items.map(__etosFormat).join(" "))
          };
          \(code)
          if (typeof main !== "function") {
            throw new Error("JavaScript 工具必须声明同步 function main(input)。");
          }
          const __etosResult = main(__etosInput);
          if (__etosResult && typeof __etosResult.then === "function") {
            throw new Error("JavaScript 工具暂不支持返回 Promise，请使用同步算法。");
          }
          return JSON.stringify({
            result: typeof __etosResult === "undefined" ? null : __etosResult,
            console: __etosConsole
          });
        })();
        """
    }

    private struct JavaScriptExecutionResult {
        let engine: AppToolCustomJSEngine
        let result: JSONValue
        let console: [String]
    }

    private struct JavaScriptExecutionEnvelope: Decodable {
        let result: JSONValue?
        let console: [String]?
    }

    nonisolated private static func parseJavaScriptEnvelope(_ rawValue: String?, engine: AppToolCustomJSEngine) throws -> JavaScriptExecutionResult {
        guard let rawValue,
              let data = rawValue.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(JavaScriptExecutionEnvelope.self, from: data) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：JavaScript 执行结果不是可解析 JSON。", comment: "JavaScript result parse error")
            )
        }
        return JavaScriptExecutionResult(
            engine: engine,
            result: envelope.result ?? .null,
            console: envelope.console ?? []
        )
    }

    private static func executeWrappedJavaScript(_ script: String, engine: AppToolCustomJSEngine) async throws -> JavaScriptExecutionResult {
        guard engine.isAvailableOnCurrentPlatform else {
            throw AppToolExecutionError.invalidArguments(
                String(
                    format: NSLocalizedString("错误：当前平台不支持 %@。", comment: "JavaScript engine unavailable with engine name"),
                    engine.displayName
                )
            )
        }

        switch engine {
        case .javaScriptCore:
            #if canImport(JavaScriptCore) && !os(watchOS)
            return try await executeWrappedJavaScriptWithJavaScriptCore(script)
            #else
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：当前平台不支持 Apple JavaScriptCore。", comment: "JavaScriptCore unavailable")
            )
            #endif
        case .webKitBridge:
            #if os(watchOS)
            return try await executeWrappedJavaScriptWithWebKitBridge(script)
            #else
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：当前平台不支持 watchOS WebKit JavaScript bridge。", comment: "WebKit bridge unavailable")
            )
            #endif
        }
    }

    #if canImport(JavaScriptCore) && !os(watchOS)
    private static func executeWrappedJavaScriptWithJavaScriptCore(_ script: String) async throws -> JavaScriptExecutionResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = JSContext()
                let value = context?.evaluateScript(script)
                if let exception = context?.exception?.toString() {
                    continuation.resume(throwing: AppToolExecutionError.invalidArguments(exception))
                    return
                }
                do {
                    continuation.resume(
                        returning: try parseJavaScriptEnvelope(
                            value?.toString(),
                            engine: .javaScriptCore
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    #endif

    #if os(watchOS)
    @MainActor
    private static func executeWrappedJavaScriptWithWebKitBridge(_ script: String) async throws -> JavaScriptExecutionResult {
        // watchOS 的 WebKit 不通过公开 Swift 模块暴露，这里只在运行时桥接 WKWebView。
        _ = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_LAZY)
        guard let webViewClass = NSClassFromString("WKWebView") as? NSObject.Type else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：当前 watchOS 运行时没有可用的 WKWebView。", comment: "watchOS WebKit bridge unavailable")
            )
        }
        let webView = webViewClass.init()
        let selector = NSSelectorFromString("evaluateJavaScript:completionHandler:")
        guard webView.responds(to: selector) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：当前 watchOS WKWebView 不支持 evaluateJavaScript。", comment: "watchOS evaluateJavaScript unavailable")
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            let completion: @convention(block) (Any?, Error?) -> Void = { value, error in
                if let error {
                    continuation.resume(throwing: AppToolExecutionError.invalidArguments(error.localizedDescription))
                    return
                }
                do {
                    continuation.resume(
                        returning: try parseJavaScriptEnvelope(
                            value as? String,
                            engine: .webKitBridge
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            let completionObject = unsafeBitCast(completion, to: AnyObject.self)
            webView.perform(selector, with: script as NSString, with: completionObject)
        }
    }
    #endif
}

extension AppToolManager {
    static var customJSToolsDirectoryURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("CustomJSTools", isDirectory: true)
    }

    static func customJSToolDirectoryURL(id: String, engine: AppToolCustomJSEngine) -> URL {
        customJSToolsDirectoryURL
            .appendingPathComponent(engine.rawValue, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    static var defaultCustomJSToolParametersSchema: JSONValue {
        .dictionary([
            "type": .string("object"),
            "additionalProperties": .bool(true),
            "description": .string(NSLocalizedString("整包参数会作为 input 传给自定义 JavaScript 工具的 main(input)。", comment: "Default custom JS tool input parameter description"))
        ])
    }

    static func loadCustomJSToolsFromDisk() -> [AppToolCustomJSTool] {
        let rootURL = customJSToolsDirectoryURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return AppToolCustomJSEngine.allCases.flatMap { engine -> [AppToolCustomJSTool] in
            let engineURL = rootURL.appendingPathComponent(engine.rawValue, isDirectory: true)
            guard let directories = try? FileManager.default.contentsOfDirectory(
                at: engineURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return [AppToolCustomJSTool]()
            }
            return directories.compactMap { directoryURL in
                let manifestURL = directoryURL.appendingPathComponent("manifest.json", isDirectory: false)
                guard let data = try? Data(contentsOf: manifestURL),
                      var tool = try? decoder.decode(AppToolCustomJSTool.self, from: data) else {
                    return nil
                }
                tool.engine = engine
                return tool
            }
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func persistCustomJSTool(_ tool: AppToolCustomJSTool) {
        let directoryURL = Self.customJSToolDirectoryURL(id: tool.id, engine: tool.engine)
        let manifestURL = directoryURL.appendingPathComponent("manifest.json", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Self.writeCustomJSToolManifest(tool, to: manifestURL)
        } catch {
            Self.logger.error("自定义 JavaScript 工具持久化失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    static func writeCustomJSToolManifest(_ tool: AppToolCustomJSTool, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tool)
        try data.write(to: url, options: .atomic)
    }

    static func normalizedCustomJSToolID(_ rawID: String?, fallbackName: String) throws -> String {
        let source = normalizedOptionalText(rawID) ?? fallbackName
        let lowered = source.lowercased()
        var result = ""
        for scalar in lowered.unicodeScalars {
            if (97...122).contains(Int(scalar.value)) || (48...57).contains(Int(scalar.value)) {
                result.append(Character(scalar))
            } else if scalar == "_" || scalar == "-" || scalar == " " {
                result.append("_")
            }
        }
        while result.contains("__") {
            result = result.replacingOccurrences(of: "__", with: "_")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.isEmpty {
            result = "tool_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "_"))"
        }
        if let firstScalar = result.unicodeScalars.first,
           !(97...122).contains(Int(firstScalar.value)) {
            result = "tool_\(result)"
        }
        if result.count > 48 {
            result = String(result.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }
        guard result.range(of: #"^[a-z][a-z0-9_]{2,47}$"#, options: .regularExpression) != nil else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：tool_id 必须以小写英文字母开头，仅包含小写字母、数字和下划线，长度 3 到 48。", comment: "Invalid custom JS tool id")
            )
        }
        return result
    }
}
