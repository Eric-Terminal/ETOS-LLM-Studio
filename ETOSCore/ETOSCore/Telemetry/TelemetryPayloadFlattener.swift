// ============================================================================
// TelemetryPayloadFlattener.swift
// ============================================================================
// ETOS LLM Studio
//
// 在进入 Codable 前压平 MetricKit 调用栈，避免递归树反复解码、复制和编码。
// ============================================================================

import Foundation
import CryptoKit

enum TelemetryPayloadFlattener {
    static let payloadFormat = "metric-kit-flat-v1"
    static let callStackFormat = "flat-v1"
    static let maximumSourceBytes = 8 * 1_024 * 1_024
    static let maximumSourceNestingDepth = 256
    static let maximumCallStackFrames = 4_096
    static let maximumConvertedValues = 50_000
    static let maximumConvertedDepth = 32

    private static let metadataKey = "_etos"
    private static let exceptionReasonKey = "exceptionReason"
    private static let callStackTreeKey = "callStackTree"
    private static let allowedExceptionReasonFields: Set<String> = [
        "exceptionType",
        "className"
    ]

    private struct TransformationState {
        var remainingFrames = maximumCallStackFrames
        var remainingValues = maximumConvertedValues
        var remainingDiagnostics = 0
        var emittedFrames = 0
        var didTruncate = false
    }

    private struct PendingFrame {
        let value: [String: Any]
        let parentFrameID: Int?
        let depth: Int
    }

    static func flatten(_ rawPayloadData: Data) throws -> JSONValue {
        let truncationReason: String?
        let object: Any
        if isWithinDecodingLimits(rawPayloadData) {
            truncationReason = nil
            object = try JSONSerialization.jsonObject(with: rawPayloadData)
        } else {
            truncationReason = rawPayloadData.count > maximumSourceBytes ? "source_size_limit" : "source_nesting_limit"
            object = try TelemetryBoundedJSONReader.read(rawPayloadData)
        }
        guard let dictionary = object as? [String: Any] else {
            throw TelemetryEnvelopeError.payloadIsNotJSONObject
        }

        var state = TransformationState()
        state.remainingDiagnostics = dictionary.reduce(0) { count, entry in
            count + (entry.key.hasSuffix("Diagnostics") ? (entry.value as? [Any])?.count ?? 0 : 0)
        }
        state.didTruncate = truncationReason != nil
        var flattened: [String: JSONValue] = [:]
        flattened.reserveCapacity(dictionary.count + 1)
        for key in dictionary.keys.sorted(by: conversionOrder) where key != metadataKey {
            guard let value = dictionary[key] else { continue }
            let converted = convert(value, key: key, depth: 0, state: &state)
            if key.caseInsensitiveCompare(exceptionReasonKey) == .orderedSame,
               case .dictionary(let retained) = converted,
               retained.isEmpty {
                continue
            }
            flattened[key] = converted
        }
        flattened[metadataKey] = metadata(
            emittedFrames: state.emittedFrames,
            didTruncate: state.didTruncate
        )
        if let truncationReason, let metadataValue = flattened[metadataKey], case .dictionary(var info) = metadataValue {
            info["source_truncated"] = .string(truncationReason)
            info["source_bytes"] = .int(rawPayloadData.count)
            info["source_sha256"] = .string(hash(rawPayloadData))
            flattened[metadataKey] = .dictionary(info)
        }
        return .dictionary(flattened)
    }

    private static func convert(
        _ value: Any,
        key: String?,
        depth: Int,
        state: inout TransformationState
    ) -> JSONValue {
        guard state.remainingValues > 0 else {
            state.didTruncate = true
            return emptyContainerPreservingType(value)
        }
        state.remainingValues -= 1

        if let key, key.caseInsensitiveCompare(exceptionReasonKey) == .orderedSame {
            return sanitizeExceptionReason(value, depth: depth, state: &state)
        }
        if let key, key.caseInsensitiveCompare(callStackTreeKey) == .orderedSame {
            return flattenCallStackTree(value, state: &state)
        }
        guard depth < maximumConvertedDepth else {
            state.didTruncate = true
            return emptyContainerPreservingType(value)
        }

        switch value {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let doubleValue = value.doubleValue
            if doubleValue.isFinite,
               doubleValue.rounded(.towardZero) == doubleValue,
               doubleValue >= Double(Int.min),
               doubleValue < Double(Int.max) {
                return .int(value.intValue)
            }
            return .double(doubleValue)
        case let value as [String: Any]:
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(value.count)
            for childKey in value.keys.sorted(by: conversionOrder) {
                guard state.remainingValues > 0 else {
                    state.didTruncate = true
                    break
                }
                guard let child = value[childKey] else { continue }
                let converted = convert(
                    child,
                    key: childKey,
                    depth: depth + 1,
                    state: &state
                )
                if childKey.caseInsensitiveCompare(exceptionReasonKey) == .orderedSame,
                   case .dictionary(let retained) = converted,
                   retained.isEmpty {
                    continue
                }
                result[childKey] = converted
            }
            return .dictionary(result)
        case let value as [Any]:
            var result: [JSONValue] = []
            result.reserveCapacity(min(value.count, state.remainingValues))
            for child in value {
                guard state.remainingValues > 0 else {
                    state.didTruncate = true
                    break
                }
                if depth == 0, key?.hasSuffix("Diagnostics") == true {
                    // 同一回调可带回多条甚至多类诊断；为尚未处理的事件预留份额，
                    // 防止第一棵大栈耗尽整份信封预算，连后续版本元数据也一起丢失。
                    let count = max(1, state.remainingDiagnostics)
                    let reservedValues = state.remainingValues - max(1, state.remainingValues / count)
                    let reservedFrames = state.remainingFrames - min(state.remainingFrames, max(1, state.remainingFrames / count))
                    state.remainingValues -= reservedValues
                    state.remainingFrames -= reservedFrames
                    state.remainingDiagnostics -= 1
                    result.append(convert(child, key: nil, depth: depth + 1, state: &state))
                    state.remainingValues += reservedValues
                    state.remainingFrames += reservedFrames
                } else {
                    result.append(convert(child, key: nil, depth: depth + 1, state: &state))
                }
            }
            return .array(result)
        case is NSNull:
            return .null
        default:
            state.didTruncate = true
            return .null
        }
    }

    private static func sanitizeExceptionReason(
        _ value: Any,
        depth: Int,
        state: inout TransformationState
    ) -> JSONValue {
        guard let dictionary = value as? [String: Any] else {
            state.didTruncate = true
            return .dictionary([:])
        }

        var retained: [String: JSONValue] = [:]
        for key in dictionary.keys.sorted() {
            let isAllowed = allowedExceptionReasonFields.contains { allowed in
                key.caseInsensitiveCompare(allowed) == .orderedSame
            }
            guard isAllowed, let child = dictionary[key] else { continue }
            retained[key] = convert(child, key: nil, depth: depth + 1, state: &state)
        }
        return .dictionary(retained)
    }

    private static func flattenCallStackTree(
        _ value: Any,
        state: inout TransformationState
    ) -> JSONValue {
        guard let tree = value as? [String: Any] else {
            state.didTruncate = true
            return .dictionary([
                "format": .string(callStackFormat),
                "callStacks": .array([]),
                "truncated": .bool(true)
            ])
        }

        var result: [String: JSONValue] = [
            "format": .string(callStackFormat)
        ]
        for key in tree.keys.sorted() where key != "callStacks" && key != metadataKey {
            guard let child = tree[key] else { continue }
            result[key] = convert(child, key: key, depth: 0, state: &state)
        }

        let sourceStacks = tree["callStacks"] as? [Any] ?? []
        let indexedStacks = Array(sourceStacks.enumerated())
        let rawStacks = indexedStacks.filter { ($0.element as? [String: Any])?["threadAttributed"] as? Bool == true }
            + indexedStacks.filter { ($0.element as? [String: Any])?["threadAttributed"] as? Bool != true }
        var flattenedStacks: [JSONValue] = []
        flattenedStacks.reserveCapacity(rawStacks.count)
        var treeWasTruncated = false

        for rawStack in rawStacks {
            guard let stack = rawStack.element as? [String: Any] else {
                treeWasTruncated = true
                state.didTruncate = true
                continue
            }

            var flattenedStack: [String: JSONValue] = [:]
            for key in stack.keys.sorted() where key != "callStackRootFrames" && key != metadataKey {
                guard let child = stack[key] else { continue }
                flattenedStack[key] = convert(child, key: key, depth: 0, state: &state)
            }

            let rootFrames = stack["callStackRootFrames"] as? [Any] ?? []
            var pending = rootFrames.reversed().compactMap { rawFrame -> PendingFrame? in
                guard let frame = rawFrame as? [String: Any] else { return nil }
                return PendingFrame(value: frame, parentFrameID: nil, depth: 0)
            }
            if pending.count != rootFrames.count {
                treeWasTruncated = true
                state.didTruncate = true
            }

            var frames: [JSONValue] = []
            var emittedRootFrames = 0
            while let current = pending.popLast() {
                guard state.remainingFrames > 0 else {
                    treeWasTruncated = true
                    state.didTruncate = true
                    break
                }
                state.remainingFrames -= 1
                let frameID = state.emittedFrames
                state.emittedFrames += 1
                if current.depth == 0 { emittedRootFrames += 1 }

                var flattenedFrame: [String: JSONValue] = [
                    "frameID": .int(frameID),
                    "depth": .int(current.depth)
                ]
                if let parentFrameID = current.parentFrameID {
                    flattenedFrame["parentFrameID"] = .int(parentFrameID)
                }
                for key in current.value.keys.sorted() where key != "subFrames" {
                    guard let child = current.value[key] else { continue }
                    flattenedFrame[key] = convert(child, key: key, depth: 0, state: &state)
                }
                frames.append(.dictionary(flattenedFrame))

                let childFrames = current.value["subFrames"] as? [Any] ?? []
                let pendingChildren = childFrames.reversed().compactMap { rawFrame -> PendingFrame? in
                    guard let frame = rawFrame as? [String: Any] else { return nil }
                    return PendingFrame(
                        value: frame,
                        parentFrameID: frameID,
                        depth: current.depth + 1
                    )
                }
                if pendingChildren.count != childFrames.count {
                    treeWasTruncated = true
                    state.didTruncate = true
                }
                pending.append(contentsOf: pendingChildren)
            }
            if !pending.isEmpty {
                treeWasTruncated = true
            }

            flattenedStack["callStackFrames"] = .array(frames)
            let sourceCounts = stack[metadataKey] as? TelemetryBoundedJSONReader.SourceArrayCounts
            let sourceRootCount = sourceCounts?.values["callStackRootFrames"]
                ?? (stack["callStackRootFrames"] as? [Any])?.count
            // 原始计数来自裁剪之前；null 表示字段缺失或结构未知，不能解释成系统给了空栈。
            flattenedStack[metadataKey] = .dictionary([
                "source_stack_index": .int(sourceCounts?.stackIndex ?? rawStack.offset),
                "source_root_frames": sourceRootCount.map(JSONValue.int) ?? .null,
                "decoded_root_frames": .int(rootFrames.count),
                "emitted_root_frames": .int(emittedRootFrames),
                "emitted_frames": .int(frames.count)
            ])
            flattenedStacks.append(.dictionary(flattenedStack))

            guard state.remainingFrames > 0 else {
                if flattenedStacks.count < rawStacks.count {
                    treeWasTruncated = true
                    state.didTruncate = true
                }
                break
            }
        }

        result["callStacks"] = .array(flattenedStacks)
        let sourceCounts = tree[metadataKey] as? TelemetryBoundedJSONReader.SourceArrayCounts
        let sourceStackCount = sourceCounts?.values["callStacks"] ?? (tree["callStacks"] as? [Any])?.count
        result[metadataKey] = .dictionary([
            "source_stacks": sourceStackCount.map(JSONValue.int) ?? .null,
            "decoded_stacks": .int(sourceStacks.count),
            "emitted_stacks": .int(flattenedStacks.count)
        ])
        result["truncated"] = .bool(treeWasTruncated)
        return .dictionary(result)
    }

    private static func metadata(
        emittedFrames: Int,
        didTruncate: Bool
    ) -> JSONValue {
        .dictionary([
            "format": .string(payloadFormat),
            "call_stack_frames_emitted": .int(emittedFrames),
            "truncated": .bool(didTruncate)
        ])
    }

    private static func conversionOrder(_ left: String, _ right: String) -> Bool {
        func priority(_ key: String) -> Int {
            switch key.lowercased() {
            case "metadata", "diagnosticmetadata": return 0
            case "callstacktree": return 2
            default: return 1
            }
        }
        let lhs = priority(left)
        let rhs = priority(right)
        return lhs == rhs ? left < right : lhs < rhs
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func emptyContainerPreservingType(_ value: Any) -> JSONValue {
        if value is [String: Any] {
            return .dictionary([:])
        }
        if value is [Any] {
            return .array([])
        }
        return .null
    }

    static func isWithinDecodingLimits(_ data: Data) -> Bool {
        data.count <= maximumSourceBytes &&
            maximumNestingDepth(in: data) <= maximumSourceNestingDepth
    }

    private static func maximumNestingDepth(in data: Data) -> Int {
        var depth = 0
        var maximumDepth = 0
        var isInsideString = false
        var isEscaping = false

        for byte in data {
            if isInsideString {
                if isEscaping {
                    isEscaping = false
                } else if byte == 0x5C {
                    isEscaping = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
                continue
            }

            switch byte {
            case 0x22:
                isInsideString = true
            case 0x7B, 0x5B:
                depth += 1
                maximumDepth = max(maximumDepth, depth)
            case 0x7D, 0x5D:
                depth = max(0, depth - 1)
            default:
                break
            }
        }
        return maximumDepth
    }
}
