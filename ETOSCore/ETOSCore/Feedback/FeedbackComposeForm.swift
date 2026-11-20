import Combine
import SwiftUI

public extension EnvironmentValues {
    @Entry var feedbackGuidePresentation: Binding<Bool>? = nil
}

/// 三端共用本地草稿、原生确认和提交入口。向导执行器只持有表单状态。
public struct FeedbackComposeForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.feedbackGuidePresentation) private var guidePresentation
    @State private var draft = FeedbackDraft(category: .bug, title: "", detail: "")
    @State private var revision = UUID()
    @State private var detailRevision = UUID()
    @State private var validDetailRevision: UUID?
    @State private var showsOptionalDetails = false
    @State private var isSubmitting = false
    @State private var environmentSummary = ""
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    @State private var assistance: Task<Void, Never>?

    private let pageID: GuidePageID
    private let isActive: Bool
    private let service: FeedbackService
    private let controller: GuideConversationController
    private let adaptKeyboard: (Binding<String>) -> Binding<String>
    private let prepareGuide: () -> Void

    public init(pageID: GuidePageID, isActive: Bool = true, service: FeedbackService,
                controller: GuideConversationController, adaptKeyboard: @escaping (Binding<String>) -> Binding<String> = { $0 },
                prepareGuide: @escaping () -> Void = {}) {
        self.pageID = pageID
        self.isActive = isActive
        self.service = service
        self.controller = controller
        self.adaptKeyboard = adaptKeyboard
        self.prepareGuide = prepareGuide
    }

    public var body: some View {
        container
            .navigationTitle(NSLocalizedString("新建反馈", value: "New Feedback", comment: ""))
            .disabled(!isActive || isSubmitting)
            .onAppear(perform: revealFilledDetails)
            .task(id: detailRevision) {
                let text = draft.detail
                let checkedRevision = detailRevision
                let ready = await Task.detached { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.value
                guard !Task.isCancelled, detailRevision == checkedRevision else { return }
                validDetailRevision = ready ? checkedRevision : nil
            }
            .task {
                environmentSummary = await Task.detached(priority: .utility) {
                    let snapshot = FeedbackEnvironmentCollector.collectSnapshot()
                    #if os(macOS)
                    let device = snapshot.osVersion
                    #else
                    let device = snapshot.deviceModel
                    #endif
                    return String(format: NSLocalizedString("将自动附带环境信息：%@ %@ (Build %@) · %@ · %@", value: "Environment info will be attached automatically: %@ %@ (Build %@) · %@ · %@", comment: "Environment summary"),
                        snapshot.platform, snapshot.appVersion, snapshot.appBuild, device, snapshot.localizedDistributionChannel)
                }.value
            }
            .guidePageContext(descriptor: FeedbackDraftGuideSupport.descriptor(pageID: pageID), isActive: isActive,
                snapshot: { FeedbackDraftGuideSupport.snapshot(draft, submitting: isSubmitting) },
                buildProposal: { call, _ in
                    guard !isSubmitting else { throw GuideError.pageChanged }
                    let current = draft
                    let version = revision
                    let id = pageID
                    return try await Task.detached {
                        try FeedbackDraftGuideSupport.proposal(for: call, draft: current, pageID: id, revision: version)
                    }.value
                }, execute: { proposal in
                    guard !isSubmitting else { throw GuideError.pageChanged }
                    let next = UUID()
                    var updated = draft
                    let result = try FeedbackDraftGuideSupport.apply(proposal, to: &updated, pageID: pageID, revision: revision, nextRevision: next)
                    draft = updated
                    revision = next
                    detailRevision = next
                    revealFilledDetails()
                    return result
                })
            .onChange(of: isActive) { _, active in
                if !active { operation?.cancel(); assistance?.cancel() }
            }
            .onChange(of: guidePresentation?.wrappedValue) { _, presented in
                if presented != true { assistance?.cancel() }
            }
            .onDisappear {
                operation?.cancel()
                if guidePresentation?.wrappedValue != true { assistance?.cancel() }
            }
            .alert(NSLocalizedString("提交失败", value: "Submission Failed", comment: ""),
                   isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(NSLocalizedString("确定", value: "OK", comment: ""), role: .cancel) {}
            } message: { Text(error ?? "") }
    }

    @ViewBuilder private var container: some View {
        #if os(watchOS)
        List { sections }
        #elseif os(macOS)
        Form { sections }.formStyle(.grouped)
        #else
        Form { sections }
        #endif
    }

    @ViewBuilder private var sections: some View {
        Section {
            Picker(NSLocalizedString("反馈类型", value: "Feedback Type", comment: ""), selection: Binding(get: { draft.category }, set: {
                draft.category = $0
                revision = UUID()
                revealFilledDetails()
            })) {
                ForEach(FeedbackCategory.allCases) { Text($0.localizedTitle).tag($0) }
            }
        }
        Section {
            TextField(NSLocalizedString("详细描述", value: "Description", comment: ""), text: adaptKeyboard(Binding(get: { draft.detail }, set: {
                draft.detail = $0
                revision = UUID()
                detailRevision = revision
            })), axis: .vertical).lineLimit(4...8)
        } footer: {
            Text(NSLocalizedString("feedback.compose.hint", value: "Tell us what happened, what you tapped, or which error code you saw. Please leave out API keys, passwords and personal contact details.", comment: "反馈描述提示"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
            Button(action: organize) {
                Label(NSLocalizedString("让助手帮我理清描述", value: "Help Me Organize My Feedback", comment: ""), systemImage: "sparkles")
            }
            .disabled(!canSubmit)
        }
        #if os(watchOS)
        Section {
            Button { showsOptionalDetails.toggle() } label: {
                Label(optionalTitle, systemImage: showsOptionalDetails ? "chevron.up" : "chevron.down")
            }
        }
        if showsOptionalDetails { Section { optionalFields } }
        #else
        Section {
            DisclosureGroup(isExpanded: $showsOptionalDetails) { optionalFields } label: { Text(optionalTitle) }
        }
        #endif
        Section {
            Button(action: submit) {
                if isSubmitting { ProgressView(NSLocalizedString("提交中...", value: "Submitting…", comment: "")) }
                else { Label(NSLocalizedString("提交", value: "Submit", comment: ""), systemImage: "paperplane") }
            }
            .disabled(!canSubmit)
        } footer: {
            VStack(alignment: .leading) {
                if !environmentSummary.isEmpty { Text(environmentSummary) }
                Text(NSLocalizedString("feedback.device.disclosure", value: "Your feedback and a random ID for this installation will be public on GitHub so you can follow progress. The ID lets the developer ask you follow-up questions privately in the app. Please leave out API keys and contact details such as your WeChat ID or phone number.", comment: "公开反馈与安装标识说明"))
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var canSubmit: Bool { !isSubmitting && validDetailRevision == detailRevision }
    private var optionalTitle: String {
        NSLocalizedString("补充标题与复现细节（选填）", value: "Optional Title & Details", comment: "")
    }

    @ViewBuilder private var optionalFields: some View {
        TextField(NSLocalizedString("标题（选填，留空自动生成）", value: "Title (optional, generated if left blank)", comment: ""),
                  text: adaptKeyboard(Binding(get: { draft.title }, set: { draft.title = $0; revision = UUID() })))
        if draft.category == .bug {
            TextField(NSLocalizedString("可复现步骤（可选）", value: "Steps to Reproduce (Optional)", comment: ""),
                      text: optionalText(\.reproductionSteps), axis: .vertical).lineLimit(3...6)
            TextField(NSLocalizedString("预期行为（可选）", value: "Expected Behavior (Optional)", comment: ""),
                      text: optionalText(\.expectedBehavior), axis: .vertical).lineLimit(2...5)
            TextField(NSLocalizedString("实际行为（可选）", value: "Actual Behavior (Optional)", comment: ""),
                      text: optionalText(\.actualBehavior), axis: .vertical).lineLimit(2...5)
        }
        TextField(NSLocalizedString("补充信息（可选）", value: "Additional Information (Optional)", comment: ""),
                  text: optionalText(\.extraContext), axis: .vertical).lineLimit(2...5)
    }

    private func optionalText(_ path: WritableKeyPath<FeedbackDraft, String?>) -> Binding<String> {
        adaptKeyboard(Binding(get: { draft[keyPath: path] ?? "" }, set: {
            draft[keyPath: path] = $0
            revision = UUID()
        }))
    }

    private func revealFilledDetails() {
        let bugDetails = draft.category == .bug && [draft.reproductionSteps, draft.expectedBehavior, draft.actualBehavior].contains { $0?.isEmpty == false }
        if !draft.title.isEmpty || draft.extraContext?.isEmpty == false || bugDetails { showsOptionalDetails = true }
    }

    private func organize() {
        let coordinator = GuideContextCoordinator.shared
        guard canSubmit, let presentation = guidePresentation, coordinator.activePage?.id == pageID,
              let source = coordinator.activeRegistrationToken else { return }
        let current = draft
        let version = revision
        assistance?.cancel()
        prepareGuide()
        presentation.wrappedValue = true
        assistance = Task {
            let request = await Task.detached { FeedbackDraftGuideSupport.organizationRequest(for: current) }.value
            await controller.restoreHistory()
            // 正在回答或等待用户确认时，保留那一轮。关闭助手或离开来源页即作废排队的提问。
            let availability = controller.$isResponding.combineLatest(controller.$pendingProposal, controller.$isAwaitingToolContinuation)
            for await _ in availability.values {
                guard !Task.isCancelled, !isSubmitting, version == revision, presentation.wrappedValue,
                      coordinator.activeRegistrationToken == source else { return }
                if !controller.isResponding, controller.pendingProposal == nil, !controller.isAwaitingToolContinuation {
                    controller.send(request)
                    return
                }
            }
        }
    }

    private func submit() {
        guard isActive, canSubmit else { return }
        assistance?.cancel()
        isSubmitting = true
        let current = draft
        operation = Task {
            defer { isSubmitting = false }
            do {
                let resolved = await Task.detached {
                    var result = current.withResolvedTitle()
                    if result.category != .bug {
                        result.reproductionSteps = nil
                        result.expectedBehavior = nil
                        result.actualBehavior = nil
                    }
                    return result
                }.value
                try Task.checkCancellation()
                _ = try await service.submit(draft: resolved)
                if !Task.isCancelled { dismiss() }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
