// ============================================================================
// LocalLLMGenerationConfig.swift
// ============================================================================
// ETOS LLM Studio
//
// 将用户可配置的 llama.cpp 高级参数映射为稳定的 C ABI 配置结构体。
// ============================================================================

import Foundation

struct LocalLLMGenerationConfig: Hashable, Sendable {
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
        self.contextSize = Int32(clamping: options.contextSize.clamped(to: 1...1_048_576))
        self.maxOutputTokens = Int32(clamping: options.maxOutputTokens.clamped(to: 1...131_072))
        self.gpuLayers = Int32(clamping: options.gpuLayers.clamped(to: -1...999))
        self.seed = options.seed
        self.minKeep = 0
        self.topK = Int32(clamping: options.topK.clamped(to: 0...1_000))
        self.topP = Float(options.topP.clamped(to: 0...1))
        self.minP = Float(options.minP.clamped(to: 0...1))
        self.typicalP = 1.0
        self.temperature = Float(options.temperature.clamped(to: 0...5))
        self.dynatempRange = 0.0
        self.dynatempExponent = 1.0
        self.xtcProbability = 0.0
        self.xtcThreshold = 0.1
        self.topNSigma = -1.0
        self.repeatLastN = Int32(clamping: options.repeatLastN.clamped(to: -1...1_048_576))
        self.repeatPenalty = Float(options.repeatPenalty.clamped(to: 0...4))
        self.frequencyPenalty = Float(options.frequencyPenalty.clamped(to: -2...2))
        self.presencePenalty = Float(options.presencePenalty.clamped(to: -2...2))
        self.dryMultiplier = 0.0
        self.dryBase = 1.75
        self.dryAllowedLength = 2
        self.dryPenaltyLastN = -1
        self.drySequenceBreakers = ["\n", ":", "\"", "*"]
        self.samplerKinds = LocalLLMSamplerKind.unique(options.samplerKinds)
        self.mirostat = 0
        self.mirostatTau = 5.0
        self.mirostatEta = 0.1
        self.adaptiveTarget = -1.0
        self.adaptiveDecay = 0.9
        self.grammar = options.grammar.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ignoreEOS = options.ignoreEOS

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
                samplerKinds = LocalLLMSamplerKind.unique(LocalLLMSamplerKind.parse(try nextValue()))
            case "adaptive-target":
                adaptiveTarget = try parseFloat(nextValue(), option: rawName)
            case "adaptive-decay":
                adaptiveDecay = try parseFloat(nextValue(), option: rawName)
            case "grammar":
                grammar = try nextValue()
            case "grammar-file":
                _ = try nextValue()
                throw LocalLLMEngineError.generationFailed("暂不支持从本地高级参数读取 grammar-file；请在 App 表单中粘贴 grammar 文本。")
            case "ignore-eos":
                ignoreEOS = true
            default:
                throw LocalLLMEngineError.generationFailed("暂不支持的本地 llama.cpp CLI 参数：\(rawName)")
            }
        }
    }
}

public enum LocalLLMSamplerKind: Int32, Codable, CaseIterable, Identifiable, Hashable, Sendable {
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

    public var id: Int32 {
        rawValue
    }

    public var code: String {
        switch self {
        case .penalties: return "e"
        case .dry: return "d"
        case .topNSigma: return "s"
        case .topK: return "k"
        case .typical: return "y"
        case .topP: return "p"
        case .minP: return "m"
        case .xtc: return "x"
        case .temperature: return "t"
        case .adaptive: return "a"
        }
    }

    public var title: String {
        switch self {
        case .penalties: return "Penalties"
        case .dry: return "DRY"
        case .topNSigma: return "Top-n-sigma"
        case .topK: return "Top-K"
        case .typical: return "Typical-P"
        case .topP: return "Top-P"
        case .minP: return "Min-P"
        case .xtc: return "XTC"
        case .temperature: return "Temperature"
        case .adaptive: return "Adaptive"
        }
    }

    public var localizedTitle: String {
        switch self {
        case .penalties: return "重复惩罚"
        case .dry: return "DRY 去复读"
        case .topNSigma: return "Top-n-sigma"
        case .topK: return "Top-K"
        case .typical: return "Typical-P"
        case .topP: return "Top-P"
        case .minP: return "Min-P"
        case .xtc: return "XTC"
        case .temperature: return "温度"
        case .adaptive: return "Adaptive"
        }
    }

    public var summary: String {
        switch self {
        case .penalties:
            return "先压低近期重复 token，让模型少原地打转。"
        case .dry:
            return "针对重复片段做更强抑制，适合长回复防复读。"
        case .topNSigma:
            return "按 logits 分布标准差裁掉离群候选，偏实验。"
        case .topK:
            return "只保留概率最高的一批候选，先做粗筛。"
        case .typical:
            return "保留更“典型”的候选，减少奇怪但高概率的跳字。"
        case .topP:
            return "按累计概率保留候选，控制开放程度。"
        case .minP:
            return "过滤相对概率太低的候选，常和 Top-P 搭配。"
        case .xtc:
            return "实验性地移除过于显眼的候选，增加表达变化。"
        case .temperature:
            return "最后缩放随机性，数值越高越发散。"
        case .adaptive:
            return "保留给自适应采样实验，普通场景可不启用。"
        }
    }

    public static let defaultChain: [LocalLLMSamplerKind] = parse("edskypmxt")

    public static var defaultChainString: String {
        chainString(defaultChain)
    }

    public static func chainString(_ kinds: [LocalLLMSamplerKind]) -> String {
        unique(kinds).map(\.code).joined()
    }

    public static func unique(_ kinds: [LocalLLMSamplerKind]) -> [LocalLLMSamplerKind] {
        var seen: Set<LocalLLMSamplerKind> = []
        var result: [LocalLLMSamplerKind] = []
        for kind in kinds where !seen.contains(kind) {
            seen.insert(kind)
            result.append(kind)
        }
        return result
    }

    public static func parse(_ rawValue: String) -> [LocalLLMSamplerKind] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.contains(";") || trimmed.contains("_") || trimmed.contains("-") {
            return trimmed
                .split(separator: ";")
                .compactMap { kind(named: String($0)) }
        }
        return trimmed.compactMap { kind(named: String($0)) }
    }

    public static func kind(named rawName: String) -> LocalLLMSamplerKind? {
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

public struct LocalLLMSamplerChainPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let samplerKinds: [LocalLLMSamplerKind]

    public init(id: String, title: String, summary: String, samplerKinds: [LocalLLMSamplerKind]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.samplerKinds = LocalLLMSamplerKind.unique(samplerKinds)
    }

    public var chainString: String {
        LocalLLMSamplerKind.chainString(samplerKinds)
    }

    public static let defaults = LocalLLMSamplerChainPreset(
        id: "default",
        title: "默认链",
        summary: "完整保留 llama.cpp 常用默认顺序，适合先从基准体验开始。",
        samplerKinds: LocalLLMSamplerKind.defaultChain
    )

    public static let balanced = LocalLLMSamplerChainPreset(
        id: "balanced",
        title: "均衡聊天",
        summary: "保留重复惩罚、Top-K、Top-P、Min-P 和温度，适合日常对话。",
        samplerKinds: [.penalties, .topK, .topP, .minP, .temperature]
    )

    public static let precise = LocalLLMSamplerChainPreset(
        id: "precise",
        title: "稳健问答",
        summary: "减少实验采样器，只保留基础筛选，适合需要稳定回答的场景。",
        samplerKinds: [.penalties, .topK, .topP, .temperature]
    )

    public static let creative = LocalLLMSamplerChainPreset(
        id: "creative",
        title: "创作发散",
        summary: "加入 Typical-P 和 Min-P，给写作类回复更多候选空间。",
        samplerKinds: [.penalties, .topK, .typical, .topP, .minP, .temperature]
    )

    public static let longContext = LocalLLMSamplerChainPreset(
        id: "long-context",
        title: "长文防复读",
        summary: "把 DRY 放在前段，适合长回复或长上下文里减少重复片段。",
        samplerKinds: [.penalties, .dry, .topK, .topP, .minP, .temperature]
    )

    public static let allPresets: [LocalLLMSamplerChainPreset] = [
        .defaults,
        .balanced,
        .precise,
        .creative,
        .longContext,
    ]
}

public struct LocalLLMParameterDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let aliases: [String]
    public let summary: String
    public let defaultValue: String
    public let effectScope: String

    public init(
        id: String,
        title: String,
        aliases: [String],
        summary: String,
        defaultValue: String,
        effectScope: String
    ) {
        self.id = id
        self.title = title
        self.aliases = aliases
        self.summary = summary
        self.defaultValue = defaultValue
        self.effectScope = effectScope
    }

    public var aliasText: String {
        aliases.joined(separator: " / ")
    }
}

public enum LocalLLMParameterCatalog {
    public static let contextRebuildText = "需要重建 context"
    public static let nextRequestText = "下次请求生效"
    public static let samplerText = "下次采样生效"

    public static let descriptors: [LocalLLMParameterDescriptor] = [
        LocalLLMParameterDescriptor(
            id: "contextSize",
            title: "上下文长度",
            aliases: ["--ctx-size", "--n-ctx", "-c"],
            summary: "模型一次能看到的上下文 token 数；越大越吃内存。",
            defaultValue: "\(LocalModelRecord.defaultContextSize)",
            effectScope: contextRebuildText
        ),
        LocalLLMParameterDescriptor(
            id: "maxOutputTokens",
            title: "最大输出 token",
            aliases: ["--n-predict", "--predict", "--max-tokens", "-n"],
            summary: "单次回复最多生成多少 token。",
            defaultValue: "\(LocalModelRecord.defaultMaxOutputTokens)",
            effectScope: nextRequestText
        ),
        LocalLLMParameterDescriptor(
            id: "gpuLayers",
            title: "GPU 层数",
            aliases: ["--gpu-layers", "--n-gpu-layers", "--ngl"],
            summary: "-1 表示尽量使用 Metal，0 表示强制 CPU。",
            defaultValue: "\(LocalModelRecord.defaultGPULayers)",
            effectScope: contextRebuildText
        ),
        LocalLLMParameterDescriptor(
            id: "seed",
            title: "随机种子",
            aliases: ["--seed", "-s"],
            summary: "\(LocalModelRecord.defaultSeed) 表示随机；固定种子可复现实验。",
            defaultValue: "\(LocalModelRecord.defaultSeed)",
            effectScope: samplerText
        ),
        LocalLLMParameterDescriptor(
            id: "temperature",
            title: "温度",
            aliases: ["--temp", "--temperature"],
            summary: "控制随机性；越高越发散，0 更确定。",
            defaultValue: formatDefault(LocalModelRecord.defaultTemperature),
            effectScope: samplerText
        ),
        LocalLLMParameterDescriptor(
            id: "topK",
            title: "Top-K",
            aliases: ["--top-k"],
            summary: "只保留概率最高的 K 个候选；0 通常表示关闭。",
            defaultValue: "\(LocalModelRecord.defaultTopK)",
            effectScope: samplerText
        ),
        LocalLLMParameterDescriptor(
            id: "topP",
            title: "Top-P",
            aliases: ["--top-p"],
            summary: "保留累计概率达到 P 的候选集合。",
            defaultValue: formatDefault(LocalModelRecord.defaultTopP),
            effectScope: samplerText
        ),
        LocalLLMParameterDescriptor(
            id: "minP",
            title: "Min-P",
            aliases: ["--min-p"],
            summary: "过滤相对最高概率太低的候选。",
            defaultValue: formatDefault(LocalModelRecord.defaultMinP),
            effectScope: samplerText
        ),
        LocalLLMParameterDescriptor(
            id: "repeatLastN",
            title: "重复检查窗口",
            aliases: ["--repeat-last-n"],
            summary: "回看多少 token 做重复惩罚；-1 表示回看整个上下文。",
            defaultValue: "\(LocalModelRecord.defaultRepeatLastN)",
            effectScope: samplerText
        ),
        LocalLLMParameterDescriptor(
            id: "repeatPenalty",
            title: "重复惩罚",
            aliases: ["--repeat-penalty"],
            summary: "高于 1 会压低近期重复 token。",
            defaultValue: formatDefault(LocalModelRecord.defaultRepeatPenalty),
            effectScope: samplerText
        ),
        LocalLLMParameterDescriptor(
            id: "frequencyPenalty",
            title: "频率惩罚",
            aliases: ["--frequency-penalty"],
            summary: "按 token 出现频率施加惩罚。",
            defaultValue: formatDefault(LocalModelRecord.defaultFrequencyPenalty),
            effectScope: samplerText
        ),
        LocalLLMParameterDescriptor(
            id: "presencePenalty",
            title: "存在惩罚",
            aliases: ["--presence-penalty"],
            summary: "只要 token 出现过就施加惩罚。",
            defaultValue: formatDefault(LocalModelRecord.defaultPresencePenalty),
            effectScope: samplerText
        ),
        LocalLLMParameterDescriptor(
            id: "grammar",
            title: "Grammar",
            aliases: ["--grammar"],
            summary: "粘贴 GBNF grammar 文本来约束输出格式。",
            defaultValue: "空",
            effectScope: nextRequestText
        ),
        LocalLLMParameterDescriptor(
            id: "ignoreEOS",
            title: "忽略 EOS",
            aliases: ["--ignore-eos"],
            summary: "忽略模型的结束 token，可能让回复继续生成到上限。",
            defaultValue: "关闭",
            effectScope: samplerText
        ),
        LocalLLMParameterDescriptor(
            id: "samplerKinds",
            title: "采样链",
            aliases: ["--samplers", "--sampler-seq", "--sampling-seq"],
            summary: "控制采样器执行顺序；普通设置页只显示默认或自定义。",
            defaultValue: LocalLLMSamplerKind.defaultChainString,
            effectScope: samplerText
        ),
    ]

    public static func descriptor(for id: String) -> LocalLLMParameterDescriptor {
        descriptors.first { $0.id == id } ?? LocalLLMParameterDescriptor(
            id: id,
            title: id,
            aliases: [],
            summary: "",
            defaultValue: "",
            effectScope: nextRequestText
        )
    }

    private static func formatDefault(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

public struct LocalLLMCLIStyleImportAppliedParameter: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let option: String
    public let title: String
    public let value: String

    public init(option: String, title: String, value: String) {
        self.option = option
        self.title = title
        self.value = value
    }
}

public struct LocalLLMCLIStyleImportIssue: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let option: String
    public let message: String

    public init(option: String, message: String) {
        self.option = option
        self.message = message
    }
}

public struct LocalLLMCLIStyleImportResult: Hashable, Sendable {
    public let updatedRecord: LocalModelRecord
    public let appliedParameters: [LocalLLMCLIStyleImportAppliedParameter]
    public let unsupportedParameters: [LocalLLMCLIStyleImportIssue]
    public let errorParameters: [LocalLLMCLIStyleImportIssue]

    public var hasAppliedParameters: Bool {
        !appliedParameters.isEmpty
    }
}

public enum LocalLLMCLIStyleArgumentImporter {
    public static func importArguments(_ rawArguments: String, into record: LocalModelRecord) -> LocalLLMCLIStyleImportResult {
        let arguments = splitArguments(rawArguments.trimmingCharacters(in: .whitespacesAndNewlines))
        var updatedRecord = record
        var applied: [LocalLLMCLIStyleImportAppliedParameter] = []
        var unsupported: [LocalLLMCLIStyleImportIssue] = []
        var errors: [LocalLLMCLIStyleImportIssue] = []
        var index = 0

        func appendApplied(_ option: String, _ descriptorID: String, _ value: String) {
            let descriptor = LocalLLMParameterCatalog.descriptor(for: descriptorID)
            applied.append(LocalLLMCLIStyleImportAppliedParameter(
                option: option,
                title: descriptor.title,
                value: value
            ))
        }

        while index < arguments.count {
            let token = arguments[index]
            index += 1
            guard token.hasPrefix("-") else {
                errors.append(LocalLLMCLIStyleImportIssue(option: token, message: "不是 llama.cpp-style 选项。"))
                continue
            }

            let parsed = parseOptionToken(token)
            let rawName = parsed.rawName
            let name = normalizeOptionName(rawName)

            func nextValue() -> String? {
                if let value = parsed.value {
                    return value
                }
                guard index < arguments.count else { return nil }
                let value = arguments[index]
                if isOptionToken(value) {
                    return nil
                }
                index += 1
                return value
            }

            func requireValue() -> String? {
                guard let value = nextValue() else {
                    errors.append(LocalLLMCLIStyleImportIssue(option: rawName, message: "缺少取值。"))
                    return nil
                }
                return value
            }

            switch name {
            case "ctx-size", "n-ctx", "c":
                guard let value = requireValue() else { continue }
                guard let parsedValue = Int(value) else {
                    errors.append(LocalLLMCLIStyleImportIssue(option: rawName, message: "需要整数，收到 \(value)。"))
                    continue
                }
                updatedRecord.contextSize = parsedValue.clamped(to: 1...1_048_576)
                appendApplied(rawName, "contextSize", "\(updatedRecord.contextSize)")
            case "predict", "n-predict", "max-tokens", "max-output-tokens", "n":
                guard let value = requireValue() else { continue }
                guard let parsedValue = Int(value) else {
                    errors.append(LocalLLMCLIStyleImportIssue(option: rawName, message: "需要整数，收到 \(value)。"))
                    continue
                }
                updatedRecord.maxOutputTokens = parsedValue.clamped(to: 1...131_072)
                appendApplied(rawName, "maxOutputTokens", "\(updatedRecord.maxOutputTokens)")
            case "gpu-layers", "n-gpu-layers", "ngl":
                guard let value = requireValue() else { continue }
                guard let parsedValue = Int(value) else {
                    errors.append(LocalLLMCLIStyleImportIssue(option: rawName, message: "需要整数，收到 \(value)。"))
                    continue
                }
                updatedRecord.gpuLayers = parsedValue.clamped(to: -1...999)
                appendApplied(rawName, "gpuLayers", "\(updatedRecord.gpuLayers)")
            case "seed", "s":
                guard let value = requireValue() else { continue }
                guard let parsedValue = parseSeed(value) else {
                    errors.append(LocalLLMCLIStyleImportIssue(option: rawName, message: "需要 0 到 \(UInt32.max) 的整数，-1 表示随机。"))
                    continue
                }
                updatedRecord.seed = parsedValue
                appendApplied(rawName, "seed", "\(updatedRecord.seed)")
            case "temp", "temperature":
                applyDouble(
                    rawName: rawName,
                    value: requireValue(),
                    range: 0...5,
                    descriptorID: "temperature",
                    assign: { updatedRecord.temperature = $0 },
                    applied: appendApplied,
                    errors: &errors
                )
            case "top-k", "top-k-sampling":
                guard let value = requireValue() else { continue }
                guard let parsedValue = Int(value) else {
                    errors.append(LocalLLMCLIStyleImportIssue(option: rawName, message: "需要整数，收到 \(value)。"))
                    continue
                }
                updatedRecord.topK = parsedValue.clamped(to: 0...1_000)
                appendApplied(rawName, "topK", "\(updatedRecord.topK)")
            case "top-p", "top-p-sampling":
                applyDouble(rawName: rawName, value: requireValue(), range: 0...1, descriptorID: "topP", assign: { updatedRecord.topP = $0 }, applied: appendApplied, errors: &errors)
            case "min-p":
                applyDouble(rawName: rawName, value: requireValue(), range: 0...1, descriptorID: "minP", assign: { updatedRecord.minP = $0 }, applied: appendApplied, errors: &errors)
            case "repeat-last-n":
                guard let value = requireValue() else { continue }
                guard let parsedValue = Int(value) else {
                    errors.append(LocalLLMCLIStyleImportIssue(option: rawName, message: "需要整数，收到 \(value)。"))
                    continue
                }
                updatedRecord.repeatLastN = parsedValue.clamped(to: -1...1_048_576)
                appendApplied(rawName, "repeatLastN", "\(updatedRecord.repeatLastN)")
            case "repeat-penalty":
                applyDouble(rawName: rawName, value: requireValue(), range: 0...4, descriptorID: "repeatPenalty", assign: { updatedRecord.repeatPenalty = $0 }, applied: appendApplied, errors: &errors)
            case "frequency-penalty":
                applyDouble(rawName: rawName, value: requireValue(), range: -2...2, descriptorID: "frequencyPenalty", assign: { updatedRecord.frequencyPenalty = $0 }, applied: appendApplied, errors: &errors)
            case "presence-penalty":
                applyDouble(rawName: rawName, value: requireValue(), range: -2...2, descriptorID: "presencePenalty", assign: { updatedRecord.presencePenalty = $0 }, applied: appendApplied, errors: &errors)
            case "grammar":
                guard let value = requireValue() else { continue }
                updatedRecord.grammar = value
                appendApplied(rawName, "grammar", value.isEmpty ? "空" : "已设置")
            case "ignore-eos":
                updatedRecord.ignoreEOS = true
                appendApplied(rawName, "ignoreEOS", "开启")
            case "samplers", "sampler-seq", "sampling-seq":
                guard let value = requireValue() else { continue }
                let samplerKinds = LocalLLMSamplerKind.parse(value)
                if samplerKinds.isEmpty {
                    errors.append(LocalLLMCLIStyleImportIssue(option: rawName, message: "没有识别到可用 sampler。"))
                } else {
                    updatedRecord.samplerKinds = samplerKinds
                    appendApplied(rawName, "samplerKinds", LocalLLMSamplerKind.chainString(samplerKinds))
                }
            case "grammar-file":
                _ = nextValue()
                unsupported.append(LocalLLMCLIStyleImportIssue(option: rawName, message: "iOS 沙盒下不导入任意路径文件，请改用 Grammar 文本。"))
            default:
                _ = nextValue()
                unsupported.append(LocalLLMCLIStyleImportIssue(option: rawName, message: "当前只支持常用 llama.cpp-style 参数子集。"))
            }
        }

        if !applied.isEmpty {
            updatedRecord.advancedArguments = ""
        }
        updatedRecord.normalizeGenerationParameters()

        return LocalLLMCLIStyleImportResult(
            updatedRecord: updatedRecord,
            appliedParameters: applied,
            unsupportedParameters: unsupported,
            errorParameters: errors
        )
    }

    private static func applyDouble(
        rawName: String,
        value: String?,
        range: ClosedRange<Double>,
        descriptorID: String,
        assign: (Double) -> Void,
        applied: (String, String, String) -> Void,
        errors: inout [LocalLLMCLIStyleImportIssue]
    ) {
        guard let value else { return }
        guard let parsedValue = Double(value) else {
            errors.append(LocalLLMCLIStyleImportIssue(option: rawName, message: "需要数字，收到 \(value)。"))
            return
        }
        let clampedValue = parsedValue.clamped(to: range)
        assign(clampedValue)
        applied(rawName, descriptorID, formatDouble(clampedValue))
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

private func isOptionToken(_ token: String) -> Bool {
    guard token.hasPrefix("-"), token != "-" else { return false }
    if token.hasPrefix("--") {
        return true
    }
    guard let firstValueCharacter = token.dropFirst().first else { return false }
    return !firstValueCharacter.isNumber && firstValueCharacter != "."
}

private func parseInt32(_ rawValue: String, option: String) throws -> Int32 {
    guard let value = Int32(rawValue) else {
        throw LocalLLMEngineError.generationFailed("本地高级参数整数无效：\(option) \(rawValue)")
    }
    return value
}

private func parseUInt32(_ rawValue: String, option: String) throws -> UInt32 {
    if rawValue == "-1" {
        return LocalModelRecord.defaultSeed
    }
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

private func parseSeed(_ rawValue: String) -> UInt32? {
    if rawValue == "-1" {
        return LocalModelRecord.defaultSeed
    }
    return UInt32(rawValue)
}

private func formatDouble(_ value: Double) -> String {
    let rounded = (value * 1_000).rounded() / 1_000
    if rounded.rounded() == rounded {
        return String(Int(rounded))
    }
    return String(rounded)
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
