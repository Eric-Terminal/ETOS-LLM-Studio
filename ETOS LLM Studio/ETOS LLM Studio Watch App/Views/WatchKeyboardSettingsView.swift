// ============================================================================
// WatchKeyboardSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 键盘设置
// ============================================================================

import SwiftUI
import ETOSCore
#if canImport(CepheusKeyboardKit)
import CepheusKeyboardKit
#endif

struct WatchKeyboardSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var previewText = ""

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("第三方全键盘", comment: "Third-party keyboard toggle"), isOn: thirdPartyKeyboardBinding)
            } footer: {
                Text(NSLocalizedString("不支持系统全键盘的 Apple Watch 可打开此开关使用第三方全键盘，支持中文拼音输入。", comment: "Third-party keyboard description"))
            }

            Section(NSLocalizedString("预览", comment: "Keyboard preview section")) {
                #if canImport(CepheusKeyboardKit)
                CepheusKeyboard(
                    input: $previewText,
                    prompt: LocalizedStringResource(stringLiteral: NSLocalizedString("预览...", comment: "Keyboard preview prompt")),
                    CepheusIsEnabled: true,
                    defaultLanguage: "zh-hans-pinyin"
                )
                if !previewText.isEmpty {
                    Button {
                        previewText = ""
                    } label: {
                        Label(NSLocalizedString("清空预览", comment: "Clear keyboard preview"), systemImage: "xmark.circle")
                    }
                }
                #else
                Text(NSLocalizedString("添加 CepheusKeyboardKit 依赖后可在这里预览第三方键盘。", comment: "Cepheus missing preview hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            #if canImport(CepheusKeyboardKit)
            if appConfig.watchUseThirdPartyKeyboard {
                Section {
                    NavigationLink {
                        CepheusSettingsView()
                    } label: {
                        Label(NSLocalizedString("键盘设置...", comment: "Cepheus keyboard settings entry"), systemImage: "keyboard")
                    }

                    NavigationLink {
                        CepheusCreditView()
                            .navigationTitle(NSLocalizedString("致谢", comment: "Credits title"))
                    } label: {
                        Label(NSLocalizedString("致谢", comment: "Credits entry"), systemImage: "heart")
                    }
                } footer: {
                    Text(NSLocalizedString("Powered by Cepheus Keyboard", comment: "Cepheus keyboard credit footer"))
                }
            } else {
                Section {
                    NavigationLink {
                        CepheusCreditView()
                            .navigationTitle(NSLocalizedString("致谢", comment: "Credits title"))
                    } label: {
                        Label(NSLocalizedString("致谢", comment: "Credits entry"), systemImage: "heart")
                    }
                } footer: {
                    Text(NSLocalizedString("Powered by Cepheus Keyboard", comment: "Cepheus keyboard credit footer"))
                }
            }
            #endif
        }
        .navigationTitle(NSLocalizedString("键盘", comment: "Keyboard settings title"))
    }

    private var thirdPartyKeyboardBinding: Binding<Bool> {
        Binding(
            get: { appConfig.watchUseThirdPartyKeyboard },
            set: { appConfig.watchUseThirdPartyKeyboard = $0 }
        )
    }
}
