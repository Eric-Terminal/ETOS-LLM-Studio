// ============================================================================
// ExtendedFeaturesView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件定义了“拓展功能”页面。
// 它为一些高级或实验性功能提供统一的入口和开关。
// ============================================================================

import SwiftUI
import Shared

public struct ExtendedFeaturesView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var isShowingIntroDetails = false
    
    public init() {}
    
    public var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "拓展功能",
                    summary: "集中管理工具集成、语音能力与系统维护入口。",
                    details: """
                    这个页面适合做什么
                    • 统一进入进阶功能，不打断主聊天流程。
                    • 快速定位语音、工具集成、导入和维护能力。

                    入口建议
                    • 工具中心：排查工具是否在当前会话可用。
                    • 记忆系统 / 世界书：管理长期偏好与规则知识。
                    • MCP / 快捷指令：接入外部能力和自动化流程。
                    • 存储管理 / 远程文件访问：做维护与清理。

                    使用建议
                    • 先保证核心入口可用，再逐步开启实验功能。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                NavigationLink {
                    ToolCenterView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("工具中心", comment: "Tool center title"), systemImage: "slider.horizontal.3")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("统一预览和调整聊天工具启用状态。", comment: "Tool center entry footer"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    TTSSettingsView()
                        .environmentObject(viewModel)
                } label: {
                    Label("语音朗读（TTS）", systemImage: "speaker.wave.2")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }

                NavigationLink {
                    SpeechInputSettingsView(
                        enableSpeechInput: $viewModel.enableSpeechInput,
                        selectedSpeechModel: speechModelBinding,
                        sendSpeechAsAudio: $viewModel.sendSpeechAsAudio,
                        audioRecordingFormat: $viewModel.audioRecordingFormat,
                        speechModels: viewModel.speechModels
                    )
                } label: {
                    Label("语音输入", systemImage: "mic")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("统一管理语音输入与语音朗读。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    FeedbackCenterView()
                } label: {
                    Label(NSLocalizedString("反馈助手", comment: "反馈入口"), systemImage: "text.bubble")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("在 App 内提交并追踪反馈工单", comment: "In-app feedback description"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    LongTermMemoryFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    Label("记忆系统", systemImage: "brain.head.profile")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("让 AI 根据历史偏好与事件持续优化回答。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    MCPIntegrationView()
                } label: {
                    Label("MCP 工具集成", systemImage: "network")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("配置 MCP 工具服务器，让助手调用外部能力。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    ShortcutIntegrationView()
                } label: {
                    Label("快捷指令工具集成", systemImage: "bolt.horizontal.circle")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("导入快捷指令工具并控制 AI 的调用权限。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    AgentSkillsView()
                } label: {
                    Label("Agent Skills", systemImage: "sparkles.square.filled.on.square")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("管理可按需加载的技能包，并控制是否向模型暴露 use_skill 工具。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    WorldbookSettingsView(viewModel: viewModel)
                } label: {
                    Label("世界书", systemImage: "book.pages")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("管理世界书并绑定到当前会话。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    LocalDebugView()
                } label: {
                    Label("远程文件访问", systemImage: "terminal")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("通过局域网远程访问和管理 Documents 目录。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    Label("存储管理", systemImage: "internaldrive")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("查看并清理本地模型、文件与缓存。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    ThirdPartyImportWatchHintView()
                } label: {
                    Label("第三方导入", systemImage: "square.and.arrow.down.on.square")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("请在 iPhone 端完成第三方数据导入。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    ImageGenerationFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("图片生成", comment: "Image generation feature entry title"), systemImage: "photo.on.rectangle.angled")
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("生图在独立页面发起，不影响主聊天输入区。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("拓展功能")
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .etFont(.footnote.weight(.semibold))
            Text(summary)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text("进一步了解…")
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(details)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private var speechModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedSpeechModel },
            set: { viewModel.setSelectedSpeechModel($0) }
        )
    }
}

// MARK: - 记忆系统设置

private struct LongTermMemoryFeatureView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    @AppStorage("enableMemory") private var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") private var enableMemoryWrite: Bool = true
    @State private var isShowingIntroDetails = false
    
    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "记忆系统",
                    summary: "让 AI 持续理解你的长期偏好和上下文。",
                    details: """
                    能力说明
                    • 记忆系统会在回复前检索历史信息，提升连续性。
                    • 写入开关仅影响“新增记忆”，不影响读取已有记忆。

                    推荐流程
                    1. 先开启总开关体验效果。
                    2. 对噪声敏感时可先关闭写入，仅保留读取。
                    3. 定期到记忆库管理清理低质量记忆。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle("启用记忆功能", isOn: $enableMemory)
            } footer: {
                Text("启用后，AI 将拥有记忆系统能力。它会在每次对话前检索相关记忆，并能通过工具主动学习。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }
            
            if enableMemory {
                Section {
                    Toggle("是否记录新的记忆", isOn: $enableMemoryWrite)
                } footer: {
                    Text("关闭后仅读取记忆，不保存新内容。")
                        .etFont(.footnote)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
                        NavigationLink(destination: MemorySettingsView().environmentObject(viewModel)) {
                            Label("记忆库管理", systemImage: "folder.badge.gearshape")
                        }
                    } else {
                        Label("记忆库管理 (系统版本过低)", systemImage: "folder.badge.gearshape")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .navigationTitle("记忆系统")
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .etFont(.footnote.weight(.semibold))
            Text(summary)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text("进一步了解…")
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(details)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}
