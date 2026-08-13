// ============================================================================
// ChatServiceLocalLLMDiagnostics.swift
// ============================================================================
// ETOS LLM Studio
//
// 将本地运行时错误与不含对话正文的环境快照合并为可复制诊断。
// ============================================================================

import Foundation

extension ChatService {
    func recordLocalLLMFailure(
        _ error: Error,
        record: LocalModelRecord,
        modelURL: URL,
        options: LocalLLMGenerationOptions,
        context: RequestLogContext
    ) -> String {
        let diagnostic = LocalLLMFailureDiagnostic(
            error: error,
            record: record,
            modelURL: modelURL,
            options: options,
            requestID: context.requestID
        )
        AppLog.developer(
            level: .error,
            category: "LocalLLM",
            action: "local_generation_failed",
            message: diagnostic.displayText,
            payload: diagnostic.payload.merging([
                "provider_id": context.providerID?.uuidString ?? "",
                "provider_name": context.providerName,
                "request_source": context.requestSource.rawValue,
                "session_id": context.sessionID?.uuidString ?? ""
            ]) { current, _ in current }
        )
        return diagnostic.displayText
    }
}

struct LocalLLMFailureDiagnostic {
    let displayText: String
    let payload: [String: String]

    init(
        error: Error,
        record: LocalModelRecord,
        modelURL: URL,
        options: LocalLLMGenerationOptions,
        requestID: UUID
    ) {
        let modelDirectoryPath = modelURL.deletingLastPathComponent().path
        var nativeDetail = error.localizedDescription
            .replacingOccurrences(of: modelURL.path, with: record.fileName)
            .replacingOccurrences(of: modelDirectoryPath, with: "<LocalModels>")
        if let mmprojPath = options.mmprojPath {
            nativeDetail = nativeDetail.replacingOccurrences(
                of: mmprojPath,
                with: URL(fileURLWithPath: mmprojPath).lastPathComponent
            )
        }

        let resourceValues = try? modelURL.resourceValues(forKeys: [.fileSizeKey])
        let actualFileSize = resourceValues?.fileSize.map(Int64.init)
        let environment = FeedbackEnvironmentCollector.collectSnapshot()
        let platform: String
        let effectiveGPULayers: Int
        #if os(watchOS)
        platform = "watchOS"
        effectiveGPULayers = 0
        #elseif targetEnvironment(simulator)
        platform = "simulator"
        effectiveGPULayers = 0
        #else
        platform = "iOS"
        effectiveGPULayers = options.gpuLayers < 0 ? 999 : options.gpuLayers
        #endif

        let processMemoryBytes = LocalResourceUsageMonitor.currentMemoryFootprintBytes()
        var runtimeLines = [
            "request_id=\(requestID.uuidString)",
            "platform=\(platform)",
            "os_version=\(environment.osVersion)",
            "device_model=\(environment.deviceModel)",
            "app_version=\(environment.appVersion)",
            "app_build=\(environment.appBuild)",
            "model_id=\(record.id.uuidString)",
            "model_name=\(record.sanitizedDisplayName)",
            "file_name=\(record.fileName)",
            "recorded_file_size_bytes=\(record.fileSize)",
            "actual_file_size_bytes=\(actualFileSize.map(String.init) ?? "unknown")",
            "gguf_architecture=\(record.ggufArchitecture ?? "unknown")",
            "device_memory_bytes=\(ProcessInfo.processInfo.physicalMemory)",
            "context_size=\(options.contextSize)",
            "max_output_tokens=\(options.maxOutputTokens)",
            "requested_gpu_layers=\(options.gpuLayers)",
            "effective_gpu_layers=\(effectiveGPULayers)",
            "batch_size=\(options.batchSize)",
            "ubatch_size=\(options.ubatchSize)",
            "kv_offload=\(options.kvOffload)",
            "flash_attention=\(options.flashAttention.rawValue)",
            "model_cache=\(options.useModelCache)",
            "kv_cache_reuse=\(options.reuseKVCache)"
        ]
        if let processMemoryBytes {
            runtimeLines.append("process_memory_bytes=\(processMemoryBytes)")
        }
        if let mmprojPath = options.mmprojPath {
            runtimeLines.append("mmproj_file=\(URL(fileURLWithPath: mmprojPath).lastPathComponent)")
        }

        let compactRuntimeLines = [
            "model=\(record.fileName) · architecture=\(record.ggufArchitecture ?? "unknown") · size_bytes=\(actualFileSize.map(String.init) ?? "unknown")",
            "device=\(environment.deviceModel) · os=\(environment.osVersion) · app=\(environment.appVersion)(\(environment.appBuild))",
            "context_size=\(options.contextSize) · max_output_tokens=\(options.maxOutputTokens) · gpu_layers=\(options.gpuLayers)/\(effectiveGPULayers) · batch=\(options.batchSize)/\(options.ubatchSize)",
            "memory_bytes=\(processMemoryBytes.map(String.init) ?? "unknown")/\(ProcessInfo.processInfo.physicalMemory) · kv_offload=\(options.kvOffload) · flash_attention=\(options.flashAttention.rawValue)"
        ]

        let localizedFailure = String(
            format: NSLocalizedString("本地推理失败: %@", comment: "Local LLM generation failed"),
            nativeDetail
        )
        displayText = localizedFailure + "\n\n[local-runtime]\n" + compactRuntimeLines.joined(separator: "\n")

        var values = Dictionary(uniqueKeysWithValues: runtimeLines.compactMap { line -> (String, String)? in
            guard let separator = line.firstIndex(of: "=") else { return nil }
            return (
                String(line[..<separator]),
                String(line[line.index(after: separator)...])
            )
        })
        values["error"] = nativeDetail
        payload = values
    }
}
