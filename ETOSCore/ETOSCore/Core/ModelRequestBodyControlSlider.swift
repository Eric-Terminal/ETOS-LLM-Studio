// ============================================================================
// ModelRequestBodyControlSlider.swift
// ============================================================================
// ETOS LLM Studio
//
// 将结构化选项映射为等距滑块锚点，并为兼容的数值 payload 提供分段插值。
// ============================================================================

import Foundation

public struct ModelRequestBodyControlSliderDescriptor: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        case discrete
        case continuousNumeric
    }

    public let controlID: String
    public let optionCount: Int
    public let mode: Mode
    public let automaticNumericGranularity: Double?
    public let numericGranularity: Double?

    private let options: [ModelRequestBodyControlOption]
    private let defaultOptionID: String?
    private let numericPath: [PayloadPathComponent]?
    private let numericValues: [Double]
    private let minimumNumericDifference: Double?
    private let usesIntegerPayload: Bool
    private let discreteDisplayValues: [String]

    public init?(control: ModelRequestBodyControl) {
        guard control.kind == .optionGroup, control.options.count >= 2 else { return nil }
        controlID = control.id
        optionCount = control.options.count
        options = control.options
        defaultOptionID = control.defaultOptionID
        discreteDisplayValues = control.options.map {
            Self.scalarDisplayValue(in: $0.payload) ?? $0.title
        }

        if let numericConfiguration = Self.numericConfiguration(for: control.options) {
            mode = .continuousNumeric
            numericPath = numericConfiguration.path
            numericValues = numericConfiguration.values
            minimumNumericDifference = Self.minimumPositiveDifference(
                in: numericConfiguration.values
            )
            automaticNumericGranularity = minimumNumericDifference.map { $0 * 0.1 }
            numericGranularity = Self.validGranularity(control.sliderGranularity)
                ?? automaticNumericGranularity
            usesIntegerPayload = numericConfiguration.usesIntegerPayload
        } else {
            mode = .discrete
            numericPath = nil
            numericValues = []
            minimumNumericDifference = nil
            automaticNumericGranularity = nil
            numericGranularity = nil
            usesIntegerPayload = false
        }
    }

    public var anchorStep: Double {
        1 / Double(optionCount - 1)
    }

    public var crownStep: Double {
        guard mode == .continuousNumeric,
              let numericGranularity,
              let minimumNumericDifference else {
            return anchorStep
        }
        return min(anchorStep, anchorStep * numericGranularity / minimumNumericDifference)
    }

    public var isNumericOrderAscending: Bool {
        guard mode == .continuousNumeric else { return true }
        return zip(numericValues, numericValues.dropFirst()).allSatisfy { pair in
            pair.0 <= pair.1
        }
    }

    public func optionsSortedByNumericValue() -> [ModelRequestBodyControlOption]? {
        guard mode == .continuousNumeric,
              options.count == numericValues.count else {
            return nil
        }

        return options.indices.sorted { leftIndex, rightIndex in
            let leftValue = numericValues[leftIndex]
            let rightValue = numericValues[rightIndex]
            if leftValue == rightValue {
                return leftIndex < rightIndex
            }
            return leftValue < rightValue
        }.map { options[$0] }
    }

    public func normalized(_ position: Double) -> Double {
        guard position.isFinite else { return 0 }
        return min(max(position, 0), 1)
    }

    public func isMaximumPosition(_ position: Double) -> Bool {
        abs(normalized(position) - 1) <= 0.000_001
    }

    public func position(in state: ModelRequestBodyControlState) -> Double {
        if let storedPosition = state.sliderPositionsByControlID[controlID] {
            return normalized(storedPosition)
        }
        let selectedOptionID = state.selectedOptionIDsByControlID[controlID] ?? defaultOptionID
        return position(forOptionID: selectedOptionID)
    }

    public func position(forOptionID optionID: String?) -> Double {
        guard let optionID,
              let index = options.firstIndex(where: { $0.id == optionID }) else {
            return 0
        }
        return anchorPosition(for: index)
    }

    public func anchorPosition(for index: Int) -> Double {
        normalized(Double(min(max(index, 0), optionCount - 1)) * anchorStep)
    }

    public func nearestAnchorIndex(at position: Double) -> Int {
        min(max(Int((normalized(position) / anchorStep).rounded()), 0), optionCount - 1)
    }

    public func nearestOptionID(at position: Double) -> String {
        options[nearestAnchorIndex(at: position)].id
    }

    public func crossesAnchor(from previousPosition: Double, to position: Double) -> Bool {
        let previousBucket = Int(floor(normalized(previousPosition) / anchorStep + 0.000_000_001))
        let currentBucket = Int(floor(normalized(position) / anchorStep + 0.000_000_001))
        return previousBucket != currentBucket
    }

    public func restingPosition(for position: Double) -> Double {
        let position = normalized(position)
        let nearestAnchor = anchorPosition(for: nearestAnchorIndex(at: position))
        if mode == .discrete || abs(position - nearestAnchor) <= anchorStep * 0.16 {
            return nearestAnchor
        }
        return position
    }

    public func payload(for position: Double) -> [String: JSONValue] {
        guard mode == .continuousNumeric,
              let numericPath else {
            return options[nearestAnchorIndex(at: position)].payload
        }

        let interpolatedValue = numericValue(at: position)
        let replacement: JSONValue
        if usesIntegerPayload, Self.isWholeNumber(interpolatedValue) {
            replacement = .int(Int(interpolatedValue.rounded()))
        } else {
            replacement = .double(interpolatedValue)
        }
        return Self.replacingValue(
            in: options[nearestAnchorIndex(at: position)].payload,
            at: numericPath,
            with: replacement
        )
    }

    public func displayValue(at position: Double) -> String {
        if mode == .continuousNumeric {
            let value = numericValue(at: position)
            return Self.formattedDecimal(value, granularity: numericGranularity)
        }

        return discreteDisplayValues[nearestAnchorIndex(at: position)]
    }

    private func numericValue(at position: Double) -> Double {
        guard numericValues.count >= 2 else { return numericValues.first ?? 0 }
        let scaledPosition = normalized(position) * Double(numericValues.count - 1)
        let nearestIndex = Int(scaledPosition.rounded())
        if numericValues.indices.contains(nearestIndex),
           abs(scaledPosition - Double(nearestIndex)) <= 0.000_000_001 {
            return numericValues[nearestIndex]
        }

        let lowerIndex = min(Int(floor(scaledPosition)), numericValues.count - 2)
        let fraction = scaledPosition - Double(lowerIndex)
        let lowerValue = numericValues[lowerIndex]
        let upperValue = numericValues[lowerIndex + 1]
        let interpolatedValue = lowerValue + (upperValue - lowerValue) * fraction
        guard let numericGranularity else { return interpolatedValue }

        let origin = numericValues[0]
        let quantizedValue = origin
            + ((interpolatedValue - origin) / numericGranularity).rounded() * numericGranularity
        let lowerBound = min(lowerValue, upperValue)
        let upperBound = max(lowerValue, upperValue)
        let boundedValue = min(max(quantizedValue, lowerBound), upperBound)
        return Self.roundedForDisplay(boundedValue, granularity: numericGranularity)
    }
}

private extension ModelRequestBodyControlSliderDescriptor {
    enum PayloadPathComponent: Hashable, Sendable {
        case key(String)
        case index(Int)
    }

    struct NumericLeaf: Hashable, Sendable {
        let path: [PayloadPathComponent]
        let value: Double
        let isInteger: Bool
    }

    struct NumericConfiguration {
        let path: [PayloadPathComponent]
        let values: [Double]
        let usesIntegerPayload: Bool
    }

    static func numericConfiguration(
        for options: [ModelRequestBodyControlOption]
    ) -> NumericConfiguration? {
        let leavesByOption = options.map { numericLeaves(in: .dictionary($0.payload)) }
        guard leavesByOption.allSatisfy({ $0.count == 1 }),
              let firstLeaf = leavesByOption.first?.first else {
            return nil
        }

        let leaves = leavesByOption.compactMap(\.first)
        guard leaves.count == options.count,
              leaves.allSatisfy({ $0.path == firstLeaf.path && $0.value.isFinite }) else {
            return nil
        }

        let normalizedPayloads = options.map {
            replacingValue(in: $0.payload, at: firstLeaf.path, with: .double(0))
        }
        guard let firstPayload = normalizedPayloads.first,
              normalizedPayloads.allSatisfy({ $0 == firstPayload }) else {
            return nil
        }

        return NumericConfiguration(
            path: firstLeaf.path,
            values: leaves.map(\.value),
            usesIntegerPayload: leaves.allSatisfy(\.isInteger)
        )
    }

    static func minimumPositiveDifference(in values: [Double]) -> Double? {
        let sortedValues = Array(Set(values)).sorted()
        return zip(sortedValues, sortedValues.dropFirst())
            .map { pair in pair.1 - pair.0 }
            .filter { $0.isFinite && $0 > 0 }
            .min()
    }

    static func validGranularity(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    static func numericLeaves(
        in value: JSONValue,
        path: [PayloadPathComponent] = []
    ) -> [NumericLeaf] {
        switch value {
        case .int(let value):
            return [NumericLeaf(path: path, value: Double(value), isInteger: true)]
        case .double(let value):
            return [NumericLeaf(path: path, value: value, isInteger: false)]
        case .dictionary(let dictionary):
            return dictionary.flatMap { key, value in
                numericLeaves(in: value, path: path + [.key(key)])
            }
        case .array(let array):
            return array.enumerated().flatMap { index, value in
                numericLeaves(in: value, path: path + [.index(index)])
            }
        case .string, .bool, .null:
            return []
        }
    }

    static func replacingValue(
        in payload: [String: JSONValue],
        at path: [PayloadPathComponent],
        with replacement: JSONValue
    ) -> [String: JSONValue] {
        guard case .dictionary(let replaced) = replacingValue(
            in: .dictionary(payload),
            at: ArraySlice(path),
            with: replacement
        ) else {
            return payload
        }
        return replaced
    }

    static func replacingValue(
        in value: JSONValue,
        at path: ArraySlice<PayloadPathComponent>,
        with replacement: JSONValue
    ) -> JSONValue {
        guard let component = path.first else { return replacement }
        let remainingPath = path.dropFirst()
        switch (component, value) {
        case (.key(let key), .dictionary(var dictionary)):
            guard let child = dictionary[key] else { return value }
            dictionary[key] = replacingValue(in: child, at: remainingPath, with: replacement)
            return .dictionary(dictionary)
        case (.index(let index), .array(var array)):
            guard array.indices.contains(index) else { return value }
            array[index] = replacingValue(in: array[index], at: remainingPath, with: replacement)
            return .array(array)
        default:
            return value
        }
    }

    static func scalarDisplayValue(in payload: [String: JSONValue]) -> String? {
        let values = scalarDisplayValues(in: .dictionary(payload))
        return values.count == 1 ? values[0] : nil
    }

    static func scalarDisplayValues(in value: JSONValue) -> [String] {
        switch value {
        case .string(let value):
            return [value]
        case .int(let value):
            return [String(value)]
        case .double(let value):
            return [formattedDecimal(value)]
        case .bool(let value):
            return [value ? "true" : "false"]
        case .dictionary(let dictionary):
            return dictionary.values.flatMap(scalarDisplayValues)
        case .array(let array):
            return array.flatMap(scalarDisplayValues)
        case .null:
            return ["null"]
        }
    }

    static func isWholeNumber(_ value: Double) -> Bool {
        abs(value - value.rounded()) <= 0.000_000_001
    }

    static func roundedForDisplay(_ value: Double, granularity: Double) -> Double {
        let fractionDigits = fractionDigits(for: granularity)
        let scale = pow(10, Double(fractionDigits))
        return (value * scale).rounded() / scale
    }

    static func fractionDigits(for granularity: Double?) -> Int {
        guard let granularity else { return 8 }
        for fractionDigits in 0...8 {
            let scaledValue = granularity * pow(10, Double(fractionDigits))
            let tolerance = max(1, abs(scaledValue)) * 0.000_000_001
            if abs(scaledValue - scaledValue.rounded()) <= tolerance {
                return fractionDigits
            }
        }
        return 8
    }

    static func formattedDecimal(_ value: Double, granularity: Double? = nil) -> String {
        let fractionDigits = fractionDigits(for: granularity)
        var formatted = String(
            format: "%.*f",
            locale: Locale(identifier: "en_US_POSIX"),
            fractionDigits,
            value
        )
        // 滑动期间保持粒度对应的固定宽度，避免整数锚点收缩后引发布局抖动。
        if granularity == nil, formatted.contains(".") {
            while formatted.last == "0" {
                formatted.removeLast()
            }
            if formatted.last == "." {
                formatted.removeLast()
            }
        }
        return formatted
    }
}
