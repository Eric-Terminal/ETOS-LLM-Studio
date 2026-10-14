import ETOSCore
import Foundation

struct MacRequestBodyDraft: Equatable, Sendable {
    var parameters: [String: JSONValue]
    var mode: Model.RequestBodyOverrideMode
    var rawJSON: String?
    var controls: [ModelRequestBodyControl]

    init(model: Model) {
        parameters = model.overrideParameters
        mode = model.requestBodyOverrideMode
        rawJSON = model.rawRequestBodyJSON
        controls = model.requestBodyControls
    }

    func apply(to model: inout Model) {
        model.overrideParameters = parameters
        model.requestBodyOverrideMode = mode
        model.rawRequestBodyJSON = rawJSON
        model.requestBodyControls = controls
    }

    func validate() throws {
        guard Set(controls.map(\.id)).count == controls.count else { throw MacRequestBodyDraftError.invalidControl }
        for control in controls { try MacRequestControlDraft(control).validate() }
    }

    func preview() throws -> String {
        try validate()
        let values = ModelRequestBodyControlCompiler.effectiveOverrideParameters(base: parameters, controls: controls, state: .init())
        return ParameterExpressionParser.serializeRawJSONObject(parameters: values)
    }
}

struct MacRequestControlDraft: Equatable, Sendable {
    var control: ModelRequestBodyControl
    var granularity: String
    var startColor: String
    var endColor: String

    init(_ control: ModelRequestBodyControl) {
        self.control = control
        granularity = control.sliderGranularity.map { String($0) } ?? ""
        startColor = control.sliderStartColorHex ?? ""
        endColor = control.sliderEndColorHex ?? ""
    }

    func validate() throws {
        guard !control.id.isEmpty, !control.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(control.options.map(\.id)).count == control.options.count,
              control.options.allSatisfy({ !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              control.defaultOptionID == nil || control.options.contains(where: { $0.id == control.defaultOptionID }) else {
            throw MacRequestBodyDraftError.invalidControl
        }
        if control.kind == .optionGroup, control.isSliderEnabled, control.options.count < 2 {
            throw MacRequestBodyDraftError.sliderNeedsOptions
        }
    }

    func prepared() throws -> ModelRequestBodyControl {
        try validate()
        var result = control
        let step = granularity.trimmingCharacters(in: .whitespacesAndNewlines)
        if step.isEmpty { result.sliderGranularity = nil }
        else {
            guard let number = Double(step), number.isFinite, number > 0 else { throw MacRequestBodyDraftError.invalidGranularity }
            result.sliderGranularity = number
        }
        result.sliderStartColorHex = try GuideRequestBodyControlSettingsSupport.optionalColor(from: .string(startColor))
        result.sliderEndColorHex = try GuideRequestBodyControlSettingsSupport.optionalColor(from: .string(endColor))
        return result
    }
}

enum MacRequestBodyDraftError: LocalizedError {
    case invalidControl, sliderNeedsOptions, invalidGranularity
    var errorDescription: String? {
        switch self {
        case .invalidControl: NSLocalizedString("控制和选项须有名称及唯一 ID，默认选项须存在。", comment: "")
        case .sliderNeedsOptions: NSLocalizedString("至少需要两个选项。", comment: "")
        case .invalidGranularity: NSLocalizedString("滑块粒度须留空或填写有限的正数。", comment: "")
        }
    }
}
