// ============================================================================
// WatchGuideModelSetupView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 手表端保留四种确定入口；云端密钥草稿只存在于当前视图内存。
// ============================================================================

import SwiftUI
import ETOSCore

struct WatchGuideModelSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var guideController: GuideConversationController
    @ObservedObject private var appConfig = AppConfigStore.shared
    @StateObject private var draft = GuideModelSetupDraft()
    @State private var saveError: String?
    @State private var isGuidePresented = false
    @State private var isSecretPresented = false
    @State private var secretInput = ""
    @State private var showsNoAPIAlternatives = false
    @State private var initialSetupState: GuideModelSetupState = .needsProvider

    var body: some View {
        List {
            Section {
                Text(initialSetupIntro)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("连接方式", comment: "手表首次模型配置连接方式分组")) {
                choiceButton(.cloud, title: NSLocalizedString("常见云端服务", comment: "手表首次模型配置云端选项"), icon: "cloud")
                choiceButton(.custom, title: NSLocalizedString("OpenAI 兼容地址", comment: "手表首次模型配置自定义选项"), icon: "link")
                NavigationLink {
                    LocalModelManagementView()
                } label: {
                    Label(NSLocalizedString("本地模型", comment: "手表首次模型配置本地选项"), systemImage: "cpu")
                }
                NavigationLink {
                    DeviceSyncSettingsView()
                } label: {
                    Label(NSLocalizedString("从 iPhone 同步已有配置", comment: "手表首次模型配置导入选项"), systemImage: "iphone.and.arrow.forward")
                }
            }

            if draft.choice == .cloud {
                Section(NSLocalizedString("服务", comment: "手表首次模型配置服务模板分组")) {
                    ForEach(GuideProviderTemplate.cloudTemplates) { template in
                        Button {
                            draft.applyTemplate(template)
                        } label: {
                            Label(template.name, systemImage: draft.baseURL == template.baseURL ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if draft.choice == .cloud || draft.choice == .custom {
                providerFields
                modelFields
                verificationAndSave
            }

            if showsNoAPIAlternatives {
                noAPIAlternatives
            }

            Section {
                Button {
                    GuideContextCoordinator.shared.pinActivePage()
                    isGuidePresented = true
                } label: {
                    Label(NSLocalizedString("询问页面向导", comment: "手表首次模型配置询问向导按钮"), systemImage: "questionmark.bubble")
                }
                .buttonStyle(.plain)
                NavigationLink {
                    ProviderListView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("打开完整模型管理", comment: "手表首次模型配置完整管理按钮"), systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationTitle(NSLocalizedString("配置第一个模型", comment: "手表首次模型配置标题"))
        .navigationDestination(isPresented: $isGuidePresented) {
            WatchGuideConversationView(controller: guideController)
        }
        .sheet(isPresented: $isSecretPresented, onDismiss: { secretInput = "" }) {
            NavigationStack {
                List {
                    Section {
                        SecureField(
                            NSLocalizedString("API Key", comment: "手表 API Key 安全输入字段"),
                            text: $secretInput.watchKeyboardNewlineBinding()
                        )
                        .textInputAutocapitalization(.never)
                    } footer: {
                        Text(NSLocalizedString("这里只写入内存草稿，不会作为向导消息发送。", comment: "手表首次模型配置安全输入说明"))
                    }
                    Section {
                        Button(NSLocalizedString("保存到草稿", comment: "手表首次模型配置保存密钥草稿按钮")) {
                            draft.apiKey = secretInput
                            secretInput = ""
                            isSecretPresented = false
                        }
                        Button(NSLocalizedString("取消", comment: "取消按钮"), role: .cancel) {
                            isSecretPresented = false
                        }
                    }
                }
                .navigationTitle(NSLocalizedString("填写 API Key", comment: "手表首次模型配置安全输入标题"))
            }
        }
        .alert(NSLocalizedString("无法保存模型", comment: "手表首次模型配置保存错误标题"), isPresented: saveErrorPresented) {
            Button(NSLocalizedString("好的", comment: "确认按钮"), role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: "watch-first-model-setup",
                title: NSLocalizedString("配置第一个模型", comment: "手表首次模型配置向导上下文标题"),
                mode: .modelSetup,
                documents: [GuideDocumentReference(id: "first-model-setup", title: "First Model Setup")],
                tools: [
                    GuidePageTool(definition: GuideToolCatalog.listProviderTemplates, access: .read),
                    GuidePageTool(definition: GuideToolCatalog.readProviderTemplate, access: .read),
                    GuidePageTool(definition: GuideToolCatalog.updateProviderConfiguration, access: .proposeChange),
                    GuidePageTool(definition: GuideToolCatalog.updateModelConfiguration, access: .proposeChange),
                    GuidePageTool(definition: GuideToolCatalog.requestModelSetupSecret, access: .proposeChange),
                    GuidePageTool(definition: GuideToolCatalog.proposeModelSetupTest, access: .proposeChange),
                    GuidePageTool(definition: GuideToolCatalog.proposeSetupModelSelection, access: .proposeChange),
                    GuidePageTool(definition: GuideToolCatalog.proposeModelSetupCommit, access: .proposeChange),
                    GuidePageTool(definition: GuideToolCatalog.showNoAPIAlternatives, access: .proposeChange)
                ]
            ),
            snapshot: {
                var fields = setupSnapshotFields()
                fields["choice"] = GuideSnapshotField(
                    label: NSLocalizedString("连接方式", comment: "手表首次模型配置快照字段"),
                    value: .string(draft.choice?.rawValue ?? ""),
                    access: .readOnly
                )
                fields["setup_state"] = GuideSnapshotField(
                    label: NSLocalizedString("配置状态", comment: "手表首次模型配置快照字段"),
                    value: .string(GuideModelSetupStateResolver.resolve(
                        providers: viewModel.providers,
                        selectedModel: viewModel.selectedModel
                    ).rawValue),
                    access: .readOnly
                )
                fields["fetched_model_ids"] = GuideSnapshotField(
                    label: NSLocalizedString("已获取模型 ID", comment: "手表首次模型配置快照字段"),
                    value: .array(draft.fetchedModels.map { .string($0.modelName) }),
                    access: .readOnly
                )
                return GuidePageSnapshot(fields: fields)
            },
            buildProposal: buildSetupProposal,
            execute: executeSetupProposal
        )
        .onDisappear {
            draft.apiKey = ""
        }
        .onAppear {
            initialSetupState = GuideModelSetupStateResolver.resolve(
                providers: viewModel.providers,
                selectedModel: viewModel.selectedModel
            )
        }
    }

    private var initialSetupIntro: String {
        switch initialSetupState {
        case .needsProvider:
            return NSLocalizedString("还没有可用提供商；先选择连接方式。API Key 不会提供给页面向导读取。", comment: "手表首次模型配置缺少提供商说明")
        case .needsCredential:
            return NSLocalizedString("已有提供商，但还缺少凭据。API Key 只会进入本地草稿。", comment: "手表首次模型配置缺少凭据说明")
        case .needsModel:
            return NSLocalizedString("凭据已存在，但还没有聊天模型。可从服务获取模型或手动填写 ID。", comment: "手表首次模型配置缺少模型说明")
        case .needsActivationOrSelection:
            return NSLocalizedString("已有模型，但尚未启用并选中可聊天模型。", comment: "手表首次模型配置缺少选中状态说明")
        case .ready:
            return NSLocalizedString("已有可用模型；这里可创建并验证新连接。", comment: "手表首次模型配置已就绪说明")
        }
    }

    private var providerFields: some View {
        Section(NSLocalizedString("提供商", comment: "手表首次模型配置提供商分组")) {
            TextField(NSLocalizedString("名称", comment: "提供商名称字段"), text: $draft.providerName.watchKeyboardNewlineBinding())
            TextField(NSLocalizedString("API 基础地址", comment: "API 地址字段"), text: $draft.baseURL.watchKeyboardNewlineBinding())
                .textInputAutocapitalization(.never)
            TextField(
                NSLocalizedString("聊天端点后缀", comment: "聊天端点后缀字段"),
                text: $draft.chatEndpointPath.watchKeyboardNewlineBinding()
            )
            .textInputAutocapitalization(.never)
            Button {
                secretInput = ""
                isSecretPresented = true
            } label: {
                Label(
                    NSLocalizedString("填写 API Key", comment: "手表首次模型配置安全输入入口"),
                    systemImage: draft.apiKey.isEmpty ? "key" : "checkmark.circle.fill"
                )
            }
            .buttonStyle(.plain)
            Picker(NSLocalizedString("接口格式", comment: "接口格式字段"), selection: $draft.apiFormat) {
                Text(NSLocalizedString("OpenAI", comment: "手表 API 格式名称")).tag("openai-compatible")
                Text(NSLocalizedString("Anthropic", comment: "手表 API 格式名称")).tag("anthropic")
                Text(NSLocalizedString("Gemini", comment: "手表 API 格式名称")).tag("gemini")
            }
        }
    }

    private var modelFields: some View {
        Section(NSLocalizedString("模型", comment: "手表首次模型配置模型分组")) {
            TextField(NSLocalizedString("模型 ID", comment: "模型 ID 字段"), text: $draft.modelName.watchKeyboardNewlineBinding())
                .textInputAutocapitalization(.never)
            TextField(NSLocalizedString("显示名称（可选）", comment: "模型显示名称字段"), text: $draft.modelDisplayName.watchKeyboardNewlineBinding())
            Toggle(NSLocalizedString("支持工具调用", comment: "模型工具调用开关"), isOn: $draft.enablesToolCalling)
            Button(NSLocalizedString("从服务获取模型", comment: "手表首次配置获取模型按钮")) {
                Task { await draft.fetchAvailableModels() }
            }
            .disabled(draft.isWorking || draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ForEach(draft.fetchedModels) { model in
                Button {
                    draft.chooseFetchedModel(model)
                } label: {
                    Label(model.displayName, systemImage: draft.modelName == model.modelName ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var verificationAndSave: some View {
        Section {
            Button(NSLocalizedString("测试连接", comment: "手表首次配置测试按钮")) {
                Task { await draft.testConnectivity() }
            }
            .disabled(draft.isWorking || !canTest)
            if let result = draft.connectivityResult {
                Text(result.status == .failed
                    ? NSLocalizedString("连接测试失败", comment: "模型连接失败状态")
                    : NSLocalizedString("连接测试通过", comment: "模型连接成功状态"))
                    .font(.footnote)
                    .foregroundStyle(result.status == .failed ? .red : .green)
            }
            if let error = draft.lastError, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button(NSLocalizedString("保存并使用这个模型", comment: "手表首次配置保存按钮")) {
                do {
                    _ = try draft.commit()
                    dismiss()
                } catch {
                    saveError = error.localizedDescription
                }
            }
            .disabled(!canSave || draft.isWorking)
        }
    }

    private func choiceButton(_ choice: GuideModelSetupChoice, title: String, icon: String) -> some View {
        Button {
            draft.choice = choice
            if choice == .custom {
                draft.providerName = NSLocalizedString("自定义提供商", comment: "默认自定义提供商名称")
                draft.baseURL = ""
                draft.chatEndpointPath = Provider.defaultChatEndpointPath
                draft.apiFormat = "openai-compatible"
            }
            guideController.sendSetupChoice(choice, displayName: title)
            isGuidePresented = true
        } label: {
            Label(title, systemImage: draft.choice == choice ? "checkmark.circle.fill" : icon)
        }
        .buttonStyle(.plain)
        .disabled(guideController.isRestoringHistory)
    }

    private func buildSetupProposal(
        call: InternalToolCall,
        snapshot: GuidePageSnapshot
    ) throws -> GuideActionProposal {
        let arguments = try GuideToolArguments.decode(call.arguments)
        let labels: [String: String]
        switch call.toolName {
        case GuideToolCatalog.updateProviderConfiguration.name:
            let allowedKeys: Set<String> = ["name", "base_url", "chat_endpoint_path", "api_format", "api_key"]
            try GuideToolArguments.requireOnlyKeys(allowedKeys, in: arguments)
            _ = try GuideToolArguments.optionalString("name", in: arguments)
            _ = try GuideToolArguments.optionalString("base_url", in: arguments)
            _ = try GuideToolArguments.optionalString("chat_endpoint_path", in: arguments)
            _ = try GuideToolArguments.optionalString("api_format", in: arguments)
            _ = try GuideToolArguments.optionalString("api_key", in: arguments)
            if let format = try GuideToolArguments.optionalString("api_format", in: arguments),
               !["openai-compatible", "openai-responses", "gemini", "anthropic"].contains(format) {
                throw GuideError.invalidToolArguments
            }
            labels = [
                "name": NSLocalizedString("提供商名称", comment: "手表首次模型配置向导修改字段"),
                "base_url": NSLocalizedString("API 地址", comment: "手表首次模型配置向导修改字段"),
                "chat_endpoint_path": NSLocalizedString("聊天端点后缀", comment: "手表首次模型配置向导修改字段"),
                "api_format": NSLocalizedString("API 格式", comment: "手表首次模型配置向导修改字段"),
                "api_key": NSLocalizedString("API Key", comment: "手表首次模型配置向导修改字段")
            ]
        case GuideToolCatalog.updateModelConfiguration.name:
            let allowedKeys: Set<String> = ["display_name", "model_id", "supports_tool_calling"]
            try GuideToolArguments.requireOnlyKeys(allowedKeys, in: arguments)
            _ = try GuideToolArguments.optionalString("display_name", in: arguments)
            _ = try GuideToolArguments.optionalString("model_id", in: arguments)
            _ = try GuideToolArguments.optionalBool("supports_tool_calling", in: arguments)
            labels = [
                "display_name": NSLocalizedString("模型名称", comment: "手表首次模型配置向导修改字段"),
                "model_id": NSLocalizedString("模型 ID", comment: "手表首次模型配置向导修改字段"),
                "supports_tool_calling": NSLocalizedString("支持工具调用", comment: "手表首次模型配置向导修改字段")
            ]
        case GuideToolCatalog.requestModelSetupSecret.name:
            try GuideToolArguments.requireOnlyKeys([], in: arguments)
            return operationProposal(
                call: call,
                summary: NSLocalizedString("打开 API Key 安全输入", comment: "手表首次模型配置向导提案摘要"),
                label: NSLocalizedString("安全输入", comment: "手表首次模型配置向导操作字段")
            )
        case GuideToolCatalog.proposeModelSetupTest.name:
            try GuideToolArguments.requireOnlyKeys([], in: arguments)
            guard canTest else { throw GuideError.invalidToolArguments }
            return operationProposal(
                call: call,
                summary: NSLocalizedString("测试当前模型连接", comment: "手表首次模型配置向导提案摘要"),
                label: NSLocalizedString("连接测试", comment: "手表首次模型配置向导操作字段")
            )
        case GuideToolCatalog.proposeSetupModelSelection.name:
            try GuideToolArguments.requireOnlyKeys(["model_id"], in: arguments)
            let modelID = try GuideToolArguments.string("model_id", in: arguments)
            guard draft.fetchedModels.contains(where: { $0.modelName == modelID }) else {
                throw GuideError.invalidToolArguments
            }
            return GuideActionProposal(
                pageID: "watch-first-model-setup",
                toolCallID: call.id,
                toolName: call.toolName,
                summary: NSLocalizedString("选择已获取的模型", comment: "手表首次模型配置向导提案摘要"),
                mutations: [GuideSettingMutation(
                    path: "model_id",
                    label: NSLocalizedString("模型 ID", comment: "手表首次模型配置向导修改字段"),
                    oldValue: .string(draft.modelName),
                    newValue: .string(modelID)
                )],
                arguments: arguments
            )
        case GuideToolCatalog.proposeModelSetupCommit.name:
            try GuideToolArguments.requireOnlyKeys([], in: arguments)
            guard canSave else { throw GuideError.invalidToolArguments }
            return operationProposal(
                call: call,
                summary: NSLocalizedString("保存并使用这个模型", comment: "手表首次模型配置向导提案摘要"),
                label: NSLocalizedString("最终保存", comment: "手表首次模型配置向导操作字段")
            )
        case GuideToolCatalog.showNoAPIAlternatives.name:
            try GuideToolArguments.requireOnlyKeys([], in: arguments)
            return operationProposal(
                call: call,
                summary: NSLocalizedString("显示无需自行配置 API 的官方应用", comment: "手表首次模型配置向导提案摘要"),
                label: NSLocalizedString("官方应用", comment: "手表首次模型配置向导操作字段")
            )
        default:
            throw GuideError.unsupportedTool(call.toolName)
        }
        let mutations = labels.compactMap { key, label -> GuideSettingMutation? in
            guard let newValue = arguments[key] else { return nil }
            let sensitive = key == "api_key"
            let oldValue = snapshot.fields[key]?.value
            guard sensitive || oldValue != newValue else { return nil }
            return GuideSettingMutation(
                path: key,
                label: label,
                oldValue: oldValue,
                newValue: newValue,
                isSensitive: sensitive
            )
        }
        guard !mutations.isEmpty else { throw GuideError.invalidToolArguments }
        return GuideActionProposal(
            pageID: "watch-first-model-setup",
            toolCallID: call.id,
            toolName: call.toolName,
            summary: NSLocalizedString("填写首次模型配置", comment: "手表首次模型配置向导提案摘要"),
            mutations: mutations,
            arguments: arguments
        )
    }

    private func executeSetupProposal(_ proposal: GuideActionProposal) async throws -> GuideActionExecution {
        let oldArguments = currentArguments(for: proposal)
        switch proposal.toolName {
        case GuideToolCatalog.updateProviderConfiguration.name:
            draft.choice = .custom
            if let value = try GuideToolArguments.optionalString("name", in: proposal.arguments) { draft.providerName = value }
            if let value = try GuideToolArguments.optionalString("base_url", in: proposal.arguments) { draft.baseURL = value }
            if let value = try GuideToolArguments.optionalString("chat_endpoint_path", in: proposal.arguments) {
                draft.chatEndpointPath = value
            }
            if let value = try GuideToolArguments.optionalString("api_format", in: proposal.arguments) { draft.apiFormat = value }
            if let value = try GuideToolArguments.optionalString("api_key", in: proposal.arguments) { draft.apiKey = value }
        case GuideToolCatalog.updateModelConfiguration.name:
            if let value = try GuideToolArguments.optionalString("display_name", in: proposal.arguments) { draft.modelDisplayName = value }
            if let value = try GuideToolArguments.optionalString("model_id", in: proposal.arguments) { draft.modelName = value }
            if let value = try GuideToolArguments.optionalBool("supports_tool_calling", in: proposal.arguments) {
                draft.enablesToolCalling = value
            }
        case GuideToolCatalog.requestModelSetupSecret.name:
            isGuidePresented = false
            try? await Task.sleep(for: .milliseconds(250))
            isSecretPresented = true
            return GuideActionExecution(
                message: NSLocalizedString("已打开原生安全输入界面；密钥不会发送给向导。", comment: "手表首次模型配置向导安全输入结果")
            )
        case GuideToolCatalog.proposeModelSetupTest.name:
            await draft.testConnectivity()
            let message = draft.isConnectivityVerified
                ? NSLocalizedString("连接测试通过，草稿仍未保存。", comment: "手表首次模型配置向导测试成功结果")
                : NSLocalizedString("连接测试失败，草稿仍未保存；请根据脱敏错误检查配置。", comment: "手表首次模型配置向导测试失败结果")
            return GuideActionExecution(message: message)
        case GuideToolCatalog.proposeSetupModelSelection.name:
            let modelID = try GuideToolArguments.string("model_id", in: proposal.arguments)
            guard let model = draft.fetchedModels.first(where: { $0.modelName == modelID }) else {
                throw GuideError.invalidToolArguments
            }
            draft.chooseFetchedModel(model)
            return GuideActionExecution(
                message: NSLocalizedString("已选择真实获取到的模型；请测试连接后再保存。", comment: "手表首次模型配置向导选择模型结果")
            )
        case GuideToolCatalog.proposeModelSetupCommit.name:
            _ = try draft.commit()
            return GuideActionExecution(
                message: NSLocalizedString("已保存并选中这个聊天模型。", comment: "手表首次模型配置向导最终保存结果")
            )
        case GuideToolCatalog.showNoAPIAlternatives.name:
            showsNoAPIAlternatives = true
            return GuideActionExecution(
                message: NSLocalizedString("已在配置页显示官方聊天应用入口。", comment: "手表首次模型配置向导官方应用结果")
            )
        default:
            throw GuideError.unsupportedTool(proposal.toolName)
        }
        let undoCall = InternalToolCall(
            id: UUID().uuidString,
            toolName: proposal.toolName,
            arguments: GuideToolArguments.encodedResult(.dictionary(oldArguments))
        )
        return GuideActionExecution(
            message: NSLocalizedString("已填入配置草稿，请检查后保存。", comment: "手表首次模型配置向导执行结果"),
            undoProposal: try buildSetupProposal(
                call: undoCall,
                snapshot: GuidePageSnapshot(fields: setupSnapshotFields())
            )
        )
    }

    private func operationProposal(
        call: InternalToolCall,
        summary: String,
        label: String
    ) -> GuideActionProposal {
        GuideActionProposal(
            pageID: "watch-first-model-setup",
            toolCallID: call.id,
            toolName: call.toolName,
            summary: summary,
            mutations: [GuideSettingMutation(
                path: "operation",
                label: label,
                oldValue: nil,
                newValue: .string(NSLocalizedString("等待用户确认", comment: "手表首次模型配置向导操作预览状态"))
            )],
            arguments: (try? GuideToolArguments.decode(call.arguments)) ?? [:]
        )
    }

    private func currentArguments(for proposal: GuideActionProposal) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for key in proposal.arguments.keys {
            switch key {
            case "name": values[key] = .string(draft.providerName)
            case "base_url": values[key] = .string(draft.baseURL)
            case "chat_endpoint_path": values[key] = .string(draft.chatEndpointPath)
            case "api_format": values[key] = .string(draft.apiFormat)
            case "api_key": values[key] = .string(draft.apiKey)
            case "display_name": values[key] = .string(draft.modelDisplayName)
            case "model_id": values[key] = .string(draft.modelName)
            case "supports_tool_calling": values[key] = .bool(draft.enablesToolCalling)
            default: break
            }
        }
        return values
    }

    private func setupSnapshotFields() -> [String: GuideSnapshotField] {
        [
            "name": GuideSnapshotField(label: NSLocalizedString("提供商名称", comment: "手表首次模型配置快照字段"), value: .string(draft.providerName)),
            "base_url": GuideSnapshotField(label: NSLocalizedString("API 地址", comment: "手表首次模型配置快照字段"), value: .string(draft.baseURL)),
            "chat_endpoint_path": GuideSnapshotField(label: NSLocalizedString("聊天端点后缀", comment: "手表首次模型配置快照字段"), value: .string(draft.chatEndpointPath)),
            "api_format": GuideSnapshotField(label: NSLocalizedString("API 格式", comment: "手表首次模型配置快照字段"), value: .string(draft.apiFormat)),
            "api_key": GuideSnapshotField(label: NSLocalizedString("API Key", comment: "手表首次模型配置快照字段"), value: .string(draft.apiKey), access: .writeOnly),
            "display_name": GuideSnapshotField(label: NSLocalizedString("模型名称", comment: "手表首次模型配置快照字段"), value: .string(draft.modelDisplayName)),
            "model_id": GuideSnapshotField(label: NSLocalizedString("模型 ID", comment: "手表首次模型配置快照字段"), value: .string(draft.modelName)),
            "supports_tool_calling": GuideSnapshotField(label: NSLocalizedString("支持工具调用", comment: "手表首次模型配置快照字段"), value: .bool(draft.enablesToolCalling))
        ]
    }

    private var canSave: Bool {
        !draft.providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            GuideModelSetupValidation.isValidRemoteBaseURL(draft.baseURL) &&
            !draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            draft.isConnectivityVerified
    }

    private var canTest: Bool {
        !draft.providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            GuideModelSetupValidation.isValidRemoteBaseURL(draft.baseURL) &&
            !draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var noAPIAlternatives: some View {
        Section(NSLocalizedString("直接聊天的官方应用", comment: "手表首次模型配置无 API 方案分组")) {
            if usesSimplifiedChineseAlternatives {
                Link(NSLocalizedString("豆包官方应用", comment: "手表首次模型配置官方应用入口"), destination: URL(string: "https://www.doubao.com/")!)
                Link(NSLocalizedString("DeepSeek 官方应用", comment: "手表首次模型配置官方应用入口"), destination: URL(string: "https://download.deepseek.com/app/")!)
            } else {
                Link(NSLocalizedString("Gemini 官方应用", comment: "手表首次模型配置官方应用入口"), destination: URL(string: "https://gemini.google.com/app/download")!)
                Link(NSLocalizedString("Claude 官方应用", comment: "手表首次模型配置官方应用入口"), destination: URL(string: "https://claude.com/download")!)
            }
            Text(NSLocalizedString("无需在 ETOS 中自行配置 API；账号要求、费用与地区可用性以各官方应用显示为准。", comment: "手表首次模型配置官方应用说明"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private var usesSimplifiedChineseAlternatives: Bool {
        let identifier = AppLanguagePreference.preferredLocale(rawValue: appConfig.appLanguage)
            .identifier
            .lowercased()
        return identifier.contains("zh") && !identifier.contains("hant")
    }
}
