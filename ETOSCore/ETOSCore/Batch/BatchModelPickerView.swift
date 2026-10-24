import SwiftUI

struct BatchModelPickerView: View {
    @ObservedObject var draft: BatchDraftModel
    @Environment(\.dismiss) private var dismiss
    let isActive: Bool

    var body: some View {
        List {
            Section {
                Picker(NSLocalizedString("batch.models.provider", value: "Provider", comment: ""), selection: $draft.providerID) {
                    Text(NSLocalizedString("batch.models.allProviders", value: "All Providers", comment: "")).tag("")
                    ForEach(draft.snapshot.providers) { provider in Text(provider.name).tag(provider.id) }
                }
                Toggle(NSLocalizedString("batch.models.selectedOnly", value: "Selected Only", comment: ""), isOn: $draft.selectedOnly)
            }
            Section {
                Button(draft.snapshot.allVisibleSelected
                       ? NSLocalizedString("batch.models.clearVisible", value: "Deselect Shown Models", comment: "只取消当前筛选结果")
                       : NSLocalizedString("batch.models.selectVisible", value: "Select Shown Models", comment: "只选择当前筛选结果")) {
                    draft.selectVisible(!draft.snapshot.allVisibleSelected)
                }
                .disabled(draft.isUpdating || draft.snapshot.visibleIDs.isEmpty)
            } footer: {
                Text(draft.snapshot.selectionSummary).font(.footnote).foregroundStyle(.secondary)
            }
            if draft.snapshot.groups.isEmpty {
                Text(NSLocalizedString("batch.models.noMatches", value: "No models match these filters. Try another search or show all models.", comment: "模型筛选空状态"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(draft.snapshot.groups) { group in
                Section(group.name) {
                    ForEach(group.models) { option in
                        Button {
                            draft.select(option.id, selected: !draft.selectedIDs.contains(option.id))
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(option.name).foregroundStyle(.primary)
                                    if option.name != option.modelName {
                                        Text(option.modelName).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: draft.selectedIDs.contains(option.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(draft.selectedIDs.contains(option.id) ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(draft.selectedIDs.contains(option.id) ? .isSelected : [])
                    }
                }
            }
            Section {
                Text(NSLocalizedString("batch.models.compatibility", value: "These models use a compatible API format. Batch availability and pricing still depend on the provider.", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $draft.search, prompt: NSLocalizedString("batch.models.search", value: "Search models or providers", comment: ""))
        .navigationTitle(NSLocalizedString("batch.models.choose", value: "Choose Models", comment: ""))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("完成", comment: "")) { dismiss() }
            }
        }
        .guideSettingsPageContext(id: "batch-model-picker", title: NSLocalizedString("batch.models.choose", value: "Choose Models", comment: ""),
            documents: BatchGuideSupport.documents, isActive: isActive, settings: draft.pickerGuideSettings)
    }
}
