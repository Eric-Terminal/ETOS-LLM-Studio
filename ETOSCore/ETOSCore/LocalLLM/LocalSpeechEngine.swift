// ============================================================================
// LocalSpeechEngine.swift
// ============================================================================
// ETOS LLM Studio
//
// 将常见音频格式转换为 16 kHz 单声道 PCM，并调用 FunASR GGUF 本地运行时。
// ============================================================================

import Foundation
import AVFoundation
import Darwin
import Dispatch

public enum LocalGGUFMetadata {
    public static func architecture(at modelURL: URL) -> String? {
        try? validatedArchitecture(at: modelURL)
    }

    public static func validatedArchitecture(at modelURL: URL) throws -> String {
        var architecturePointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = modelURL.path.withCString {
            etos_local_gguf_architecture(
                $0,
                &architecturePointer,
                &errorPointer
            )
        }
        defer {
            architecturePointer.map(etos_local_llm_free)
            errorPointer.map(etos_local_llm_free)
        }
        guard status == 0, let architecturePointer else {
            let message = errorPointer.map { String(cString: $0) }
                ?? LocalLLMEngineError.backendUnavailable.localizedDescription
            let missingFilePrefix = "etos.local_model_file_missing|"
            if message.hasPrefix(missingFilePrefix) {
                let fileName = message
                    .dropFirst(missingFilePrefix.count)
                    .split(whereSeparator: \.isNewline)
                    .first
                    .map(String.init) ?? ""
                throw LocalLLMEngineError.modelFileMissing(fileName)
            }
            let incompleteFilePrefix = "etos.local_model_file_incomplete|"
            if message.hasPrefix(incompleteFilePrefix) {
                let fields = message.split(
                    separator: "|",
                    maxSplits: 3,
                    omittingEmptySubsequences: false
                )
                if fields.count == 4,
                   let actualBytes = UInt64(fields[1]),
                   let requiredBytes = UInt64(fields[2]) {
                    let fileName = fields[3]
                        .split(whereSeparator: \.isNewline)
                        .first
                        .map(String.init) ?? modelURL.lastPathComponent
                    throw LocalLLMEngineError.modelFileIncomplete(
                        fileName: fileName,
                        actualBytes: actualBytes,
                        requiredBytes: requiredBytes
                    )
                }
            }
            throw LocalLLMEngineError.generationFailed(String(
                format: NSLocalizedString("无法加载文件: %@", comment: "Unable to load imported GGUF file"),
                message
            ))
        }
        return String(cString: architecturePointer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func validateLoRAAdapter(at adapterURL: URL, compatibleWith architecture: String?) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = adapterURL.path.withCString { adapterPath in
            (architecture ?? "").withCString { expectedArchitecture in
                etos_local_gguf_validate_lora_adapter(
                    adapterPath,
                    expectedArchitecture,
                    &errorPointer
                )
            }
        }
        defer { errorPointer.map(etos_local_llm_free) }
        guard status == 0 else {
            let message = errorPointer.map { String(cString: $0) }
                ?? LocalLLMEngineError.backendUnavailable.localizedDescription
            throw LocalLLMEngineError.generationFailed(String(
                format: NSLocalizedString("无法加载文件: %@", comment: "Unable to load imported GGUF file"),
                message
            ))
        }
    }
}

public struct LocalSpeechTranscriptionOptions: Hashable, Sendable {
    public var contextSize: Int
    public var maxOutputTokens: Int
    public var gpuLayers: Int
    public var threadCount: Int
    public var chunkSeconds: Int
    public var vadMaxSegmentMilliseconds: Int
    public var useModelCache: Bool

    public init(
        contextSize: Int = LocalModelRecord.defaultContextSize,
        maxOutputTokens: Int = LocalModelRecord.defaultMaxOutputTokens,
        gpuLayers: Int = LocalModelRecord.defaultGPULayers,
        threadCount: Int = 0,
        chunkSeconds: Int = 15,
        vadMaxSegmentMilliseconds: Int = 30_000,
        useModelCache: Bool = true
    ) {
        self.contextSize = contextSize.clamped(to: 256...1_048_576)
        self.maxOutputTokens = maxOutputTokens.clamped(to: 1...131_072)
        self.gpuLayers = gpuLayers.clamped(to: -1...999)
        self.threadCount = threadCount.clamped(to: 0...64)
        self.chunkSeconds = chunkSeconds.clamped(to: 1...600)
        self.vadMaxSegmentMilliseconds = vadMaxSegmentMilliseconds.clamped(to: 1_000...600_000)
        self.useModelCache = useModelCache
    }
}

public enum LocalSpeechEngineError: LocalizedError, Sendable {
    case modelFileMissing(String)
    case decoderModelFileMissing(String)
    case vadModelFileMissing(String)
    case audioConversionFailed(String)
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelFileMissing(let name):
            return String(
                format: NSLocalizedString("找不到本地语音模型文件：%@", comment: "Local speech model missing"),
                name
            )
        case .decoderModelFileMissing(let name):
            return String(
                format: NSLocalizedString("找不到本地语音解码模型文件：%@", comment: "Local speech decoder missing"),
                name
            )
        case .vadModelFileMissing(let name):
            return String(
                format: NSLocalizedString("找不到本地 VAD 模型文件：%@", comment: "Local speech VAD missing"),
                name
            )
        case .audioConversionFailed(let message):
            return String(
                format: NSLocalizedString("无法准备本地语音音频：%@", comment: "Local speech conversion failed"),
                message
            )
        case .transcriptionFailed(let message):
            return message
        }
    }
}

public enum LocalSpeechEngine {
    public static func transcribe(
        audioData: Data,
        fileExtension: String,
        modelURL: URL,
        decoderModelURL: URL? = nil,
        vadModelURL: URL? = nil,
        options: LocalSpeechTranscriptionOptions = .init()
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalSpeechEngineError.modelFileMissing(modelURL.lastPathComponent)
        }
        if let decoderModelURL,
           !FileManager.default.fileExists(atPath: decoderModelURL.path) {
            throw LocalSpeechEngineError.decoderModelFileMissing(decoderModelURL.lastPathComponent)
        }
        if let vadModelURL,
           !FileManager.default.fileExists(atPath: vadModelURL.path) {
            throw LocalSpeechEngineError.vadModelFileMissing(vadModelURL.lastPathComponent)
        }

        let cancellationState = LocalSpeechCancellationState()
        let task = Task.detached(priority: .userInitiated) {
            let samples = try convertToPCM(
                audioData: audioData,
                fileExtension: fileExtension
            )
            try Task.checkCancellation()
            return try transcribePCM(
                samples,
                modelPath: modelURL.path,
                decoderModelPath: decoderModelURL?.path ?? "",
                vadModelPath: vadModelURL?.path ?? "",
                options: options,
                cancellationState: cancellationState
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellationState.cancel()
            task.cancel()
        }
    }

    private static func convertToPCM(
        audioData: Data,
        fileExtension: String
    ) throws -> [Float] {
        let normalizedExtension = fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(normalizedExtension.isEmpty ? "m4a" : normalizedExtension)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            try audioData.write(to: temporaryURL, options: .atomic)
            let audioFile = try AVAudioFile(forReading: temporaryURL)
            let inputFormat = audioFile.processingFormat
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw LocalSpeechEngineError.audioConversionFailed(
                    NSLocalizedString("当前音频格式不受系统转换器支持。", comment: "Unsupported local speech audio format")
                )
            }

            let inputFrameCapacity = AVAudioFrameCount(
                min(UInt64(UInt32.max), UInt64(max(1, audioFile.length)))
            )
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: inputFrameCapacity
            ) else {
                throw LocalSpeechEngineError.audioConversionFailed(
                    NSLocalizedString("无法分配音频输入缓冲区。", comment: "Local speech input buffer allocation failed")
                )
            }
            try audioFile.read(into: inputBuffer)
            let estimatedFrames = ceil(
                Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate
            )
            let outputFrameCapacity = AVAudioFrameCount(
                min(Double(UInt32.max), max(1, estimatedFrames + 4_096))
            )
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputFrameCapacity
            ) else {
                throw LocalSpeechEngineError.audioConversionFailed(
                    NSLocalizedString("无法分配音频输出缓冲区。", comment: "Local speech output buffer allocation failed")
                )
            }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if status == .error {
                throw conversionError ?? LocalSpeechEngineError.audioConversionFailed(
                    NSLocalizedString("系统音频转换器返回失败。", comment: "Local speech converter failed")
                )
            }
            guard outputBuffer.frameLength > 0,
                  let samples = outputBuffer.floatChannelData?.pointee else {
                throw LocalSpeechEngineError.audioConversionFailed(
                    NSLocalizedString("音频中没有可转写的采样。", comment: "Local speech empty audio")
                )
            }
            return Array(UnsafeBufferPointer(start: samples, count: Int(outputBuffer.frameLength)))
        } catch let error as LocalSpeechEngineError {
            throw error
        } catch {
            throw LocalSpeechEngineError.audioConversionFailed(error.localizedDescription)
        }
    }

    private static func transcribePCM(
        _ samples: [Float],
        modelPath: String,
        decoderModelPath: String,
        vadModelPath: String,
        options: LocalSpeechTranscriptionOptions,
        cancellationState: LocalSpeechCancellationState
    ) throws -> String {
        var outputPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let statePointer = Unmanaged.passUnretained(cancellationState).toOpaque()
        let status = modelPath.withCString { modelPathCString in
            decoderModelPath.withCString { decoderPathCString in
                vadModelPath.withCString { vadPathCString in
                    var config = ETOSLocalSpeechConfig(
                        decoderModelPath: decoderPathCString,
                        vadModelPath: vadPathCString,
                        contextSize: Int32(options.contextSize),
                        maxOutputTokens: Int32(options.maxOutputTokens),
                        gpuLayers: Int32(options.gpuLayers),
                        threadCount: Int32(options.threadCount),
                        chunkSeconds: Int32(options.chunkSeconds),
                        vadMaxSegmentMilliseconds: Int32(options.vadMaxSegmentMilliseconds),
                        useModelCache: options.useModelCache ? 1 : 0
                    )
                    return samples.withUnsafeBufferPointer { samplesPointer in
                        etos_local_speech_transcribe(
                            modelPathCString,
                            samplesPointer.baseAddress,
                            Int32(samplesPointer.count),
                            &config,
                            localSpeechShouldCancel,
                            statePointer,
                            &outputPointer,
                            &errorPointer
                        )
                    }
                }
            }
        }
        defer {
            outputPointer.map(etos_local_llm_free)
            errorPointer.map(etos_local_llm_free)
        }
        guard status == 0, let outputPointer else {
            if status == -2 {
                throw CancellationError()
            }
            let message = errorPointer.map { String(cString: $0) }
                ?? NSLocalizedString("本地语音运行时没有返回错误详情。", comment: "Local speech missing runtime error")
            throw LocalSpeechEngineError.transcriptionFailed(message)
        }
        return String(cString: outputPointer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ETOSLocalSpeechConfig {
    var decoderModelPath: UnsafePointer<CChar>?
    var vadModelPath: UnsafePointer<CChar>?
    var contextSize: Int32
    var maxOutputTokens: Int32
    var gpuLayers: Int32
    var threadCount: Int32
    var chunkSeconds: Int32
    var vadMaxSegmentMilliseconds: Int32
    var useModelCache: Int32
}

private final class LocalSpeechCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancellationRequested = false

    func cancel() {
        lock.lock()
        isCancellationRequested = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancellationRequested
    }
}

private let localSpeechShouldCancel: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = {
    guard let userData = $0 else { return 0 }
    let state = Unmanaged<LocalSpeechCancellationState>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return state.isCancelled() ? 1 : 0
}

@_silgen_name("etos_local_gguf_architecture")
private func etos_local_gguf_architecture(
    _ modelPath: UnsafePointer<CChar>,
    _ architecture: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_gguf_validate_lora_adapter")
private func etos_local_gguf_validate_lora_adapter(
    _ adapterPath: UnsafePointer<CChar>,
    _ expectedArchitecture: UnsafePointer<CChar>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_speech_transcribe")
private func etos_local_speech_transcribe(
    _ modelPath: UnsafePointer<CChar>,
    _ audioSamples: UnsafePointer<Float>?,
    _ sampleCount: Int32,
    _ config: UnsafePointer<ETOSLocalSpeechConfig>,
    _ cancelCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?,
    _ userData: UnsafeMutableRawPointer?,
    _ output: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("etos_local_llm_free")
private func etos_local_llm_free(_ pointer: UnsafeMutablePointer<CChar>)

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
