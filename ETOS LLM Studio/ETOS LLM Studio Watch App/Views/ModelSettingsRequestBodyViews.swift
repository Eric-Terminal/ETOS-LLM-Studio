// ============================================================================
// ModelSettingsRequestBodyViews.swift
// ============================================================================
// ETOS LLM Studio Watch App 模型请求体设置辅助视图
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct RequestBodyPreview {
    let text: String
    let isPlaceholder: Bool
}

struct RequestBodyPreviewInlineView: View {
    let preview: RequestBodyPreview

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(preview.text)
                .etFont(.caption2.monospaced())
                .foregroundStyle(preview.isPlaceholder ? .secondary : .primary)
                .lineLimit(nil)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 2)
        }
    }
}

struct RequestBodyControlRow: View {
    let control: ModelRequestBodyControl

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayTitle)
                .lineLimit(1)

            Text(control.isEnabled ? NSLocalizedString("已启用", comment: "") : NSLocalizedString("已停用", comment: ""))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var displayTitle: String {
        let trimmedTitle = control.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? NSLocalizedString("未命名提示词", comment: "") : trimmedTitle
    }
}

struct RequestBodyControlImportView: View {
    @Environment(\.dismiss) private var dismiss
    let sources: [RunnableModel]
    let onImport: (RunnableModel) -> Void

    var body: some View {
        List {
            Section {
                if sources.isEmpty {
                    Text(NSLocalizedString("没有其他已配置结构化控制的模型。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sources) { source in
                        Button {
                            onImport(source)
                            dismiss()
                        } label: {
                            RequestBodyControlImportRow(source: source)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                Text(NSLocalizedString("选择后会追加来源模型的全部结构化控制，现有控制不会被替换。", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("选择来源模型", comment: ""))
    }
}

private struct RequestBodyControlImportRow: View {
    let source: RunnableModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(displayTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(source.model.modelName)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(providerAndCountText)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var displayTitle: String {
        let title = source.model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? source.model.modelName : title
    }

    private var controlCountText: String {
        String(
            format: NSLocalizedString("%d 个控制", comment: ""),
            source.model.requestBodyControls.count
        )
    }

    private var providerAndCountText: String {
        String(
            format: NSLocalizedString("%@ · %@", comment: ""),
            source.provider.name,
            controlCountText
        )
    }
}

struct RequestBodyControlDetailView: View {
    @Binding var control: ModelRequestBodyControl
    let payloadDisplayMode: Model.RequestBodyOverrideMode
    @State private var suggestedPayloadKeys: [String] = []
    @State private var automaticSliderGranularity: Double?
    @State private var sliderGranularityText = ""
    @State private var showsNumericSortAction = false

    var body: some View {
        Form {
            Section(header: Text(NSLocalizedString("基础信息", comment: ""))) {
                TextField(NSLocalizedString("显示名称", comment: ""), text: $control.title.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
            }

            Section(header: Text(NSLocalizedString("启用状态", comment: ""))) {
                Toggle(NSLocalizedString("启用", comment: ""), isOn: $control.isEnabled)
            }

            switch control.kind {
            case .toggle:
                Section(header: Text(NSLocalizedString("详情", comment: ""))) {
                    Toggle(NSLocalizedString("默认开启", comment: ""), isOn: $control.defaultIsActive)

                    RequestBodyPayloadEditor(
                        payloadDisplayMode: payloadDisplayMode,
                        payload: $control.payload,
                        suggestedPayloadKeys: []
                    )
                    .id("\(control.id)-toggle-payload")
                }
            case .optionGroup:
                Section(header: Text(NSLocalizedString("详情", comment: ""))) {
                    if control.options.isEmpty {
                        Text(NSLocalizedString("暂无", comment: ""))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(optionsBinding, id: \.id, editActions: .move) { $option in
                            let optionID = option.id
                            NavigationLink {
                                RequestBodyOptionDetailView(
                                    option: $option,
                                    defaultOptionID: $control.defaultOptionID,
                                    payloadDisplayMode: payloadDisplayMode,
                                    suggestedPayloadKeys: suggestedPayloadKeys
                                )
                            } label: {
                                RequestBodyOptionRow(
                                    option: option,
                                    isDefault: control.defaultOptionID == optionID
                                )
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteOption(withID: optionID)
                                } label: {
                                    Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                                }
                            }
                        }
                    }

                    Button {
                        addOption()
                    } label: {
                        Label(NSLocalizedString("添加", comment: ""), systemImage: "plus")
                    }
                }
            }

            if control.kind == .optionGroup {
                Section(
                    header: Text(NSLocalizedString("滑块", comment: "")),
                    footer: Text(NSLocalizedString("启用后，字符串选项会吸附到档位，数字选项可在档位之间连续调节。数字粒度默认取相邻档位最小差值的 10%，也可手动覆盖。至少需要两个选项。", comment: ""))
                ) {
                    Toggle(NSLocalizedString("启用滑块", comment: ""), isOn: $control.isSliderEnabled)
                        .disabled(control.options.count < 2)

                    if showsNumericSortAction {
                        Button(action: sortOptionsByNumericValue) {
                            Label(
                                NSLocalizedString("按数值从小到大排序", comment: ""),
                                systemImage: "arrow.up"
                            )
                        }
                    }

                    if automaticSliderGranularity != nil {
                        TextField(
                            NSLocalizedString("粒度", comment: "数值滑块每次调节的最小变化量"),
                            text: $sliderGranularityText.watchKeyboardNewlineBinding()
                        )
                        .onChange(of: sliderGranularityText) { _, text in
                            updateSliderGranularity(from: text)
                        }
                    }
                }
            }
        }
        .navigationTitle(displayTitle)
        .onAppear {
            refreshSuggestedPayloadKeys()
            refreshSliderConfiguration()
        }
        .onChange(of: control.options) { _, options in
            if options.count < 2 {
                control.isSliderEnabled = false
            }
            refreshSuggestedPayloadKeys()
            refreshSliderConfiguration()
        }
    }

    private var displayTitle: String {
        let trimmedTitle = control.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? NSLocalizedString("未命名提示词", comment: "") : trimmedTitle
    }

    private var optionsBinding: Binding<[ModelRequestBodyControlOption]> {
        Binding(
            get: { control.options },
            set: { control.options = $0 }
        )
    }

    private func refreshSuggestedPayloadKeys() {
        let keys = control.suggestedOptionPayloadKeys
        if suggestedPayloadKeys != keys {
            suggestedPayloadKeys = keys
        }
    }

    private func refreshSliderConfiguration() {
        let descriptor = ModelRequestBodyControlSliderDescriptor(control: control)
        automaticSliderGranularity = descriptor?.automaticNumericGranularity
        showsNumericSortAction = descriptor?.mode == .continuousNumeric
            && descriptor?.isNumericOrderAscending == false
        let displayedGranularity = control.sliderGranularity
            ?? descriptor?.automaticNumericGranularity
        sliderGranularityText = displayedGranularity.map(formattedGranularity) ?? ""
    }

    private func sortOptionsByNumericValue() {
        guard let sortedOptions = ModelRequestBodyControlSliderDescriptor(control: control)?
            .optionsSortedByNumericValue() else {
            return
        }
        withAnimation {
            control.options = sortedOptions
            showsNumericSortAction = false
        }
    }

    private func updateSliderGranularity(from text: String) {
        let normalizedText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let granularity = Double(normalizedText),
              granularity.isFinite,
              granularity > 0 else {
            return
        }
        if control.sliderGranularity == nil,
           let automaticSliderGranularity,
           abs(granularity - automaticSliderGranularity) <= 0.000_000_001 {
            return
        }
        control.sliderGranularity = granularity
    }

    private func formattedGranularity(_ granularity: Double) -> String {
        var formatted = String(
            format: "%.8f",
            locale: Locale(identifier: "en_US_POSIX"),
            granularity
        )
        while formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." {
            formatted.removeLast()
        }
        return formatted
    }

    private func addOption() {
        let optionID = UUID().uuidString
        control.options.append(
            ModelRequestBodyControlOption(
                id: optionID,
                title: NSLocalizedString("新选项", comment: ""),
                payload: [:]
            )
        )
        if control.defaultOptionID == nil {
            control.defaultOptionID = optionID
        }
    }

    private func deleteOptions(at offsets: IndexSet) {
        let deletedIDs = offsets.compactMap { index in
            control.options.indices.contains(index) ? control.options[index].id : nil
        }
        control.options.remove(atOffsets: offsets)
        if let defaultOptionID = control.defaultOptionID,
           deletedIDs.contains(defaultOptionID) {
            control.defaultOptionID = control.options.first?.id
        }
    }

    private func deleteOption(withID optionID: String) {
        guard let index = control.options.firstIndex(where: { $0.id == optionID }) else { return }
        deleteOptions(at: IndexSet(integer: index))
    }
}

struct RequestBodyOptionRow: View {
    let option: ModelRequestBodyControlOption
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(displayTitle)
                .lineLimit(1)

            Spacer(minLength: 8)

            if isDefault {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayTitle: String {
        let trimmedTitle = option.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? NSLocalizedString("未命名提示词", comment: "") : trimmedTitle
    }
}

struct RequestBodyOptionDetailView: View {
    @Binding var option: ModelRequestBodyControlOption
    @Binding var defaultOptionID: String?
    let payloadDisplayMode: Model.RequestBodyOverrideMode
    let suggestedPayloadKeys: [String]

    var body: some View {
        Form {
            Section(header: Text(NSLocalizedString("基础信息", comment: ""))) {
                TextField(NSLocalizedString("显示名称", comment: ""), text: $option.title.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
            }

            Section(header: Text(NSLocalizedString("启用状态", comment: ""))) {
                Toggle(NSLocalizedString("设为默认", comment: ""), isOn: defaultOptionBinding)
            }

            Section(header: Text(NSLocalizedString("详情", comment: ""))) {
                RequestBodyPayloadEditor(
                    payloadDisplayMode: payloadDisplayMode,
                    payload: $option.payload,
                    suggestedPayloadKeys: suggestedPayloadKeys
                )
                .id("\(option.id)-payload")
            }
        }
        .navigationTitle(displayTitle)
    }

    private var displayTitle: String {
        let trimmedTitle = option.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? NSLocalizedString("未命名提示词", comment: "") : trimmedTitle
    }

    private var defaultOptionBinding: Binding<Bool> {
        Binding {
            defaultOptionID == option.id
        } set: { isDefault in
            if isDefault {
                defaultOptionID = option.id
            } else if defaultOptionID == option.id {
                defaultOptionID = nil
            }
        }
    }
}

struct RequestBodyPayloadEditor: View {
    let payloadDisplayMode: Model.RequestBodyOverrideMode
    @Binding var payload: [String: JSONValue]
    let suggestedPayloadKeys: [String]
    @State private var text: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch payloadDisplayMode {
            case .rawJSON:
                textPayloadEditor(
                    title: nil,
                    placeholder: NSLocalizedString("填写 JSON 对象", comment: ""),
                    lineLimit: 2...8
                )
            case .keyValue, .expression:
                textPayloadEditor(
                    title: NSLocalizedString("覆盖参数", comment: "Request body structured control override parameters label"),
                    placeholder: NSLocalizedString("参数表达式，比如 temperature = 0.8", comment: ""),
                    lineLimit: 2...8
                )
            @unknown default:
                textPayloadEditor(
                    title: NSLocalizedString("覆盖参数", comment: "Request body structured control override parameters label"),
                    placeholder: NSLocalizedString("参数表达式，比如 temperature = 0.8", comment: ""),
                    lineLimit: 2...8
                )
            }
        }
    }

    private func textPayloadEditor(
        title: String?,
        placeholder: String,
        lineLimit: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            TextField(
                placeholder,
                text: $text.watchKeyboardNewlineBinding(),
                axis: .vertical
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(lineLimit)
            .etFont(.caption2.monospaced())
            .onAppear(perform: syncTextFromPayload)
            .onChange(of: text, initial: false) { _, newValue in
                parse(newValue)
            }
            .onChange(of: payloadDisplayMode, initial: false) { _, _ in
                syncTextFromPayload()
            }
            .onChange(of: suggestedPayloadKeys, initial: false) { _, _ in
                if payload.isEmpty {
                    syncTextFromPayload()
                }
            }

            if let error {
                Text(error)
                    .etFont(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private func syncTextFromPayload() {
        if payload.isEmpty, let suggestedText = suggestedText() {
            text = suggestedText
            error = nil
            return
        }

        switch payloadDisplayMode {
        case .rawJSON:
            text = ParameterExpressionParser.serializeRawJSONObject(parameters: payload)
        case .keyValue, .expression:
            text = ParameterExpressionParser.serialize(parameters: payload).joined(separator: "\n")
        @unknown default:
            text = ParameterExpressionParser.serialize(parameters: payload).joined(separator: "\n")
        }
    }

    private func parse(_ rawText: String) {
        if payload.isEmpty, rawText == suggestedText() {
            error = nil
            return
        }

        do {
            switch payloadDisplayMode {
            case .rawJSON:
                payload = try ParameterExpressionParser.parseRawJSONObject(rawText)
            case .keyValue, .expression:
                let lines = rawText
                    .split(whereSeparator: \.isNewline)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let expressions = try lines.map { try ParameterExpressionParser.parse($0) }
                payload = ParameterExpressionParser.buildParameters(from: expressions)
            @unknown default:
                let lines = rawText
                    .split(whereSeparator: \.isNewline)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let expressions = try lines.map { try ParameterExpressionParser.parse($0) }
                payload = ParameterExpressionParser.buildParameters(from: expressions)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func suggestedText() -> String? {
        guard !suggestedPayloadKeys.isEmpty else { return nil }
        switch payloadDisplayMode {
        case .rawJSON:
            let placeholderPayload = Dictionary(
                uniqueKeysWithValues: suggestedPayloadKeys.map { ($0, JSONValue.null) }
            )
            return ParameterExpressionParser.serializeRawJSONObject(parameters: placeholderPayload)
        case .keyValue, .expression:
            return suggestedPayloadKeys.map { "\($0) = " }.joined(separator: "\n")
        @unknown default:
            return suggestedPayloadKeys.map { "\($0) = " }.joined(separator: "\n")
        }
    }
}

struct KeyValueRow: View {
    @Binding var entry: ModelSettingsView.KeyValueEntry

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Key", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                TextField(NSLocalizedString("Key", comment: ""), text: $entry.key.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Value", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                TextField(NSLocalizedString("Value", comment: ""), text: $entry.value.watchKeyboardNewlineBinding(), axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...4)
            }

            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

struct ExpressionRow: View {
    @Binding var entry: ModelSettingsView.ExpressionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(NSLocalizedString("比如 temperature = 0.8", comment: ""), text: $entry.text.watchKeyboardNewlineBinding())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
