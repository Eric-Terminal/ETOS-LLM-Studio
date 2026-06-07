// ============================================================================
// ModelSettingsRequestBodyViews.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 iOS 模型设置页中自定义请求体预览、结构化控制和参数编辑子视图。
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
                .foregroundStyle(preview.isPlaceholder ? .secondary : .primary)
                .lineLimit(nil)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
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
                .etFont(.caption)
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
                TextField(NSLocalizedString("显示名称", comment: ""), text: $control.title)
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
                TextField(NSLocalizedString("显示名称", comment: ""), text: $option.title)
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
        VStack(alignment: .leading, spacing: 6) {
            switch payloadDisplayMode {
            case .keyValue:
                RequestBodyPayloadKeyValueEditor(payload: $payload)
            case .rawJSON:
                textPayloadEditor(
                    title: nil,
                    placeholder: NSLocalizedString("填写 JSON 对象", comment: ""),
                    lineLimit: 2...8
                )
            default:
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
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField(placeholder, text: $text, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(lineLimit)
                .onAppear(perform: syncTextFromPayload)
                .onChange(of: text) { _, newValue in
                    parse(newValue)
                }
                .onChange(of: payloadDisplayMode) { _, _ in
                    syncTextFromPayload()
                }

            if let error {
                Text(error)
                    .etFont(.footnote)
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

struct RequestBodyPayloadKeyValueEntry: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: String
    var error: String?

    init(id: UUID = UUID(), key: String, value: String, error: String? = nil) {
        self.id = id
        self.key = key
        self.value = value
        self.error = error
    }
}

struct RequestBodyPayloadKeyValueEditor: View {
    @Binding var payload: [String: JSONValue]
    @State private var entries: [RequestBodyPayloadKeyValueEntry] = []

    var body: some View {
        Group {
            ForEach($entries) { $entry in
                RequestBodyPayloadKeyValueRow(
                    entry: $entry,
                    canDelete: entries.count > 1,
                    onDelete: {
                        deleteEntry(withID: entry.id)
                    },
                    onChange: updatePayload
                )
            }

            Button {
                entries.append(RequestBodyPayloadKeyValueEntry(key: "", value: ""))
            } label: {
                Label(NSLocalizedString("添加键值对", comment: ""), systemImage: "plus")
            }
        }
        .onAppear(perform: syncEntriesFromPayload)
    }

    private func syncEntriesFromPayload() {
        let rows = payload
            .sorted(by: { $0.key < $1.key })
            .map { RequestBodyPayloadKeyValueEntry(key: $0.key, value: stringValue(for: $0.value)) }
        entries = rows.isEmpty ? [RequestBodyPayloadKeyValueEntry(key: "", value: "")] : rows
    }

    private func updatePayload() {
        var updatedEntries = entries
        var parsedExpressions: [ParameterExpressionParser.ParsedExpression] = []
        var hasError = false

        for index in updatedEntries.indices {
            do {
                if let expression = try parseEntry(updatedEntries[index]) {
                    parsedExpressions.append(expression)
                }
                updatedEntries[index].error = nil
            } catch {
                hasError = true
                updatedEntries[index].error = error.localizedDescription
            }
        }

        entries = updatedEntries
        guard !hasError else { return }
        payload = ParameterExpressionParser.buildParameters(from: parsedExpressions)
    }

    private func parseEntry(_ entry: RequestBodyPayloadKeyValueEntry) throws -> ParameterExpressionParser.ParsedExpression? {
        let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && value.isEmpty {
            return nil
        }
        guard !key.isEmpty else {
            throw ParameterExpressionParser.ParserError.invalidKey
        }
        if value.isEmpty {
            return ParameterExpressionParser.ParsedExpression(key: key, value: .string(""))
        }
        return try ParameterExpressionParser.parse("\(key) = \(entry.value)")
    }

    private func deleteEntry(withID id: UUID) {
        entries.removeAll { $0.id == id }
        if entries.isEmpty {
            entries.append(RequestBodyPayloadKeyValueEntry(key: "", value: ""))
        }
        updatePayload()
    }

    private func stringValue(for value: JSONValue) -> String {
        let serialized = ParameterExpressionParser.serialize(parameters: ["value": value]).first ?? "value="
        guard let separatorIndex = serialized.firstIndex(of: "=") else {
            return serialized
        }
        return String(serialized[serialized.index(after: separatorIndex)...])
    }
}

struct RequestBodyPayloadKeyValueRow: View {
    @Binding var entry: RequestBodyPayloadKeyValueEntry
    let canDelete: Bool
    let onDelete: () -> Void
    let onChange: () -> Void

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Key", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
                TextField(NSLocalizedString("Key", comment: ""), text: $entry.key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Value", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
                TextField(NSLocalizedString("Value", comment: ""), text: $entry.value, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...4)
            }

            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }

            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .onChange(of: entry.key) { _, _ in onChange() }
        .onChange(of: entry.value) { _, _ in onChange() }
    }
}

struct KeyValueRow: View {
    @Binding var entry: ModelSettingsView.KeyValueEntry

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Key", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
                TextField(NSLocalizedString("Key", comment: ""), text: $entry.key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .etFont(.body.monospaced())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Value", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
                TextField(NSLocalizedString("Value", comment: ""), text: $entry.value, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...4)
                    .etFont(.body.monospaced())
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
        VStack(alignment: .leading, spacing: 6) {
            TextField(NSLocalizedString("参数表达式，比如 temperature = 0.8", comment: ""), text: $entry.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .etFont(.body.monospaced())

            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
