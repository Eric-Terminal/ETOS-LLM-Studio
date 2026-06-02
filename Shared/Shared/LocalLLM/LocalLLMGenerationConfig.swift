// ============================================================================
// LocalLLMGenerationConfig.swift
// ============================================================================
// ETOS LLM Studio
//
// 将用户可配置的 llama.cpp 高级参数映射为稳定的 C ABI 配置结构体。
// ============================================================================

import Foundation

struct LocalLLMGenerationConfig: Hashable, Sendable {
    static let defaultSeed: UInt32 = UInt32.max

    var contextSize: Int32
    var maxOutputTokens: Int32
    var gpuLayers: Int32
    var seed: UInt32
    var minKeep: Int32
    var topK: Int32
    var topP: Float
    var minP: Float
    var typicalP: Float
    var temperature: Float
    var dynatempRange: Float
    var dynatempExponent: Float
    var xtcProbability: Float
    var xtcThreshold: Float
    var topNSigma: Float
    var repeatLastN: Int32
    var repeatPenalty: Float
    var frequencyPenalty: Float
    var presencePenalty: Float
    var dryMultiplier: Float
    var dryBase: Float
    var dryAllowedLength: Int32
    var dryPenaltyLastN: Int32
    var drySequenceBreakers: [String]
    var samplerKinds: [LocalLLMSamplerKind]
    var mirostat: Int32
    var mirostatTau: Float
    var mirostatEta: Float
    var adaptiveTarget: Float
    var adaptiveDecay: Float
    var grammar: String
    var ignoreEOS: Bool

    init(options: LocalLLMGenerationOptions) throws {
        self.contextSize = Int32(clamping: options.contextSize)
        self.maxOutputTokens = Int32(clamping: options.maxOutputTokens)
        self.gpuLayers = Int32(clamping: options.gpuLayers)
        self.seed = Self.defaultSeed
        self.minKeep = 0
        self.topK = 40
        self.topP = Float(options.topP ?? 0.95)
        self.minP = 0.05
        self.typicalP = 1.0
        self.temperature = Float(options.temperature ?? 0.8)
        self.dynatempRange = 0.0
        self.dynatempExponent = 1.0
        self.xtcProbability = 0.0
        self.xtcThreshold = 0.1
        self.topNSigma = -1.0
        self.repeatLastN = 64
        self.repeatPenalty = 1.0
        self.frequencyPenalty = 0.0
        self.presencePenalty = 0.0
        self.dryMultiplier = 0.0
        self.dryBase = 1.75
        self.dryAllowedLength = 2
        self.dryPenaltyLastN = -1
        self.drySequenceBreakers = ["\n", ":", "\"", "*"]
        self.samplerKinds = LocalLLMSamplerKind.parse("edskypmxt")
        self.mirostat = 0
        self.mirostatTau = 5.0
        self.mirostatEta = 0.1
        self.adaptiveTarget = -1.0
        self.adaptiveDecay = 0.9
        self.grammar = ""
        self.ignoreEOS = false

        try applyAdvancedArguments(options.advancedArguments)
    }

    private mutating func applyAdvancedArguments(_ rawArguments: String) throws {
        let raw = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        let arguments = splitArguments(raw)
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            guard token.hasPrefix("-") else {
                throw LocalLLMEngineError.generationFailed("本地高级参数必须使用 llama.cpp CLI 风格选项：\(token)")
            }

            let parsed = parseOptionToken(token)
            let rawName = parsed.rawName
            let name = normalizeOptionName(rawName)

            func nextValue() throws -> String {
                if let value = parsed.value {
                    return value
                }
                guard index < arguments.count else {
                    throw LocalLLMEngineError.generationFailed("本地高级参数缺少取值：\(rawName)")
                }
                defer { index += 1 }
                return arguments[index]
            }

            switch name {
            case "ctx-size", "n-ctx", "c":
                contextSize = try parseInt32(nextValue(), option: rawName)
            case "predict", "n-predict", "max-tokens", "max-output-tokens", "n":
                maxOutputTokens = try parseInt32(nextValue(), option: rawName)
            case "gpu-layers", "n-gpu-layers", "ngl":
                gpuLayers = try parseInt32(nextValue(), option: rawName)
            case "seed", "s":
                seed = try parseUInt32(nextValue(), option: rawName)
            case "temp", "temperature":
                temperature = try parseFloat(nextValue(), option: rawName)
            case "top-k", "top-k-sampling":
                topK = try parseInt32(nextValue(), option: rawName)
            case "top-p", "top-p-sampling":
                topP = try parseFloat(nextValue(), option: rawName)
            case "min-p":
                minP = try parseFloat(nextValue(), option: rawName)
            case "min-keep":
                minKeep = try parseInt32(nextValue(), option: rawName)
            case "typical", "typical-p", "typ-p":
                typicalP = try parseFloat(nextValue(), option: rawName)
            case "dynatemp-range":
                dynatempRange = try parseFloat(nextValue(), option: rawName)
            case "dynatemp-exp":
                dynatempExponent = try parseFloat(nextValue(), option: rawName)
            case "xtc-probability":
                xtcProbability = try parseFloat(nextValue(), option: rawName)
            case "xtc-threshold":
                xtcThreshold = try parseFloat(nextValue(), option: rawName)
            case "top-n-sigma":
                topNSigma = try parseFloat(nextValue(), option: rawName)
            case "repeat-last-n":
                repeatLastN = try parseInt32(nextValue(), option: rawName)
            case "repeat-penalty":
                repeatPenalty = try parseFloat(nextValue(), option: rawName)
            case "frequency-penalty":
                frequencyPenalty = try parseFloat(nextValue(), option: rawName)
            case "presence-penalty":
                presencePenalty = try parseFloat(nextValue(), option: rawName)
            case "dry-multiplier":
                dryMultiplier = try parseFloat(nextValue(), option: rawName)
            case "dry-base":
                dryBase = try parseFloat(nextValue(), option: rawName)
            case "dry-allowed-length":
                dryAllowedLength = try parseInt32(nextValue(), option: rawName)
            case "dry-penalty-last-n":
                dryPenaltyLastN = try parseInt32(nextValue(), option: rawName)
            case "dry-sequence-breaker":
                let breaker = try nextValue()
                if drySequenceBreakers == ["\n", ":", "\"", "*"] {
                    drySequenceBreakers.removeAll()
                }
                if breaker != "none" {
                    drySequenceBreakers.append(breaker)
                }
            case "mirostat":
                mirostat = try parseInt32(nextValue(), option: rawName)
            case "mirostat-lr":
                mirostatEta = try parseFloat(nextValue(), option: rawName)
            case "mirostat-ent":
                mirostatTau = try parseFloat(nextValue(), option: rawName)
            case "samplers", "sampler-seq", "sampling-seq":
                samplerKinds = LocalLLMSamplerKind.parse(try nextValue())
            case "adaptive-target":
                adaptiveTarget = try parseFloat(nextValue(), option: rawName)
            case "adaptive-decay":
                adaptiveDecay = try parseFloat(nextValue(), option: rawName)
            case "grammar":
                grammar = try nextValue()
            case "grammar-file":
                let path = try nextValue()
                do {
                    grammar = try String(contentsOfFile: path, encoding: .utf8)
                } catch {
                    throw LocalLLMEngineError.generationFailed("无法读取本地高级参数 grammar 文件：\(path)")
                }
            case "ignore-eos":
                ignoreEOS = true
            default:
                throw LocalLLMEngineError.generationFailed("暂不支持的本地 llama.cpp CLI 参数：\(rawName)")
            }
        }
    }
}

enum LocalLLMSamplerKind: Int32, Hashable, Sendable {
    case penalties = 1
    case dry = 2
    case topNSigma = 3
    case topK = 4
    case typical = 5
    case topP = 6
    case minP = 7
    case xtc = 8
    case temperature = 9
    case adaptive = 10

    static func parse(_ rawValue: String) -> [LocalLLMSamplerKind] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.contains(";") || trimmed.contains("_") || trimmed.contains("-") {
            return trimmed
                .split(separator: ";")
                .compactMap { kind(named: String($0)) }
        }
        return trimmed.compactMap { kind(named: String($0)) }
    }

    private static func kind(named rawName: String) -> LocalLLMSamplerKind? {
        switch normalizeOptionName(rawName.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case "e", "penalties":
            return .penalties
        case "d", "dry":
            return .dry
        case "s", "top-n-sigma":
            return .topNSigma
        case "k", "top-k":
            return .topK
        case "y", "typ-p", "typical", "typical-p":
            return .typical
        case "p", "top-p", "nucleus":
            return .topP
        case "m", "min-p":
            return .minP
        case "x", "xtc":
            return .xtc
        case "t", "temp", "temperature":
            return .temperature
        case "a", "adaptive-p":
            return .adaptive
        default:
            return nil
        }
    }
}

private func splitArguments(_ raw: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quote: Character?
    var escaping = false

    for character in raw {
        if escaping {
            current.append(character)
            escaping = false
            continue
        }
        if character == "\\" {
            escaping = true
            continue
        }
        if let activeQuote = quote {
            if character == activeQuote {
                quote = nil
            } else {
                current.append(character)
            }
            continue
        }
        if character == "'" || character == "\"" {
            quote = character
            continue
        }
        if character.isWhitespace {
            if !current.isEmpty {
                result.append(current)
                current.removeAll()
            }
            continue
        }
        current.append(character)
    }

    if escaping {
        current.append("\\")
    }
    if !current.isEmpty {
        result.append(current)
    }
    return result
}

private func parseOptionToken(_ token: String) -> (rawName: String, value: String?) {
    guard let equals = token.firstIndex(of: "=") else {
        return (token, nil)
    }
    return (String(token[..<equals]), String(token[token.index(after: equals)...]))
}

private func normalizeOptionName(_ rawName: String) -> String {
    rawName
        .drop { $0 == "-" }
        .map { $0 == "_" ? "-" : Character($0.lowercased()) }
        .map(String.init)
        .joined()
}

private func parseInt32(_ rawValue: String, option: String) throws -> Int32 {
    guard let value = Int32(rawValue) else {
        throw LocalLLMEngineError.generationFailed("本地高级参数整数无效：\(option) \(rawValue)")
    }
    return value
}

private func parseUInt32(_ rawValue: String, option: String) throws -> UInt32 {
    guard let value = UInt32(rawValue) else {
        throw LocalLLMEngineError.generationFailed("本地高级参数整数无效：\(option) \(rawValue)")
    }
    return value
}

private func parseFloat(_ rawValue: String, option: String) throws -> Float {
    guard let value = Float(rawValue) else {
        throw LocalLLMEngineError.generationFailed("本地高级参数数字无效：\(option) \(rawValue)")
    }
    return value
}
