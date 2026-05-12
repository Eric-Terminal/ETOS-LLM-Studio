// ============================================================================
// ModelSettingsRequestBodyViews.swift
// ============================================================================
// ETOS LLM Studio Watch App 模型请求体设置辅助视图
// ============================================================================

import SwiftUI
import Foundation
import Shared

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

struct RequestBodyControlDetailView: View {
    @Binding var control: ModelRequestBodyControl
    let payloadDisplayMode: Model.RequestBodyOverrideMode

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
                        payload: $control.payload
                    )
                    .id("\(control.id)-toggle-payload")
                }
            case .optionGroup:
                Section(header: Text(NSLocalizedString("详情", comment: ""))) {
                    if control.options.isEmpty {
                        Text(NSLocalizedString("暂无", comment: ""))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($control.options) { $option in
                            let optionID = option.id
                            NavigationLink {
                                RequestBodyOptionDetailView(
                                    option: $option,
                                    defaultOptionID: $control.defaultOptionID,
                                    payloadDisplayMode: payloadDisplayMode
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
        }
        .navigationTitle(displayTitle)
    }

    private var displayTitle: String {
        let trimmedTitle = control.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? NSLocalizedString("未命名提示词", comment: "") : trimmedTitle
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
                    payload: $option.payload
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

            if let error {
                Text(error)
                    .etFont(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private func syncTextFromPayload() {
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
