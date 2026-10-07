// ============================================================================
// ETOSMacApp.swift
// ============================================================================
// 独立的原生 macOS 入口；窗口共享核心服务，防止重复初始化数据库与请求路由。
// ============================================================================

import AppKit
import ETOSCore
import SwiftUI

@main
struct ETOSMacApp: App {
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var applicationDelegate
    @StateObject private var workspace = MacWorkspaceModel()

    var body: some Scene {
        Window(NSLocalizedString("ETOS LLM Studio", comment: ""), id: "workspace") {
            MacLaunchView()
                .environmentObject(workspace)
                .frame(minWidth: 760, minHeight: 520)
                .disabled(applicationDelegate.isTerminating)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(NSLocalizedString("新建对话", comment: "")) { workspace.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(applicationDelegate.isTerminating || workspace.phase != .ready || workspace.isRestoringData)
            }
            CommandGroup(after: .pasteboard) {
                Button(NSLocalizedString("停止生成", comment: "")) { workspace.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(applicationDelegate.isTerminating || !workspace.isGenerating)
            }
        }
        Settings {
            if workspace.phase == .ready {
                MacSettingsView()
                    .environmentObject(workspace)
                    .disabled(applicationDelegate.isTerminating)
            } else {
                Text(NSLocalizedString("请先解锁数据库。", comment: ""))
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }
}

private struct MacLaunchView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel

    var body: some View {
        Group {
            switch workspace.phase {
            case .loading:
                ProgressView(NSLocalizedString("正在加载…", comment: ""))
            case .locked:
                DatabaseUnlockOverlayView { Task { await workspace.start() } }
            case .recovery:
                VStack {
                    Label(NSLocalizedString("恢复数据库", comment: ""), systemImage: "externaldrive.badge.exclamationmark")
                        .font(.title2)
                    Text(workspace.recoveryRequest?.message ?? "")
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("从备份恢复", comment: "")) {
                        Task { await workspace.restoreStartupBackup() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            case .ready:
                MacWorkspaceView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await workspace.start() }
        .alert(NSLocalizedString("错误", comment: ""), isPresented: Binding(
            get: { workspace.errorMessage != nil },
            set: { if !$0 { workspace.errorMessage = nil } }
        )) {
            Button(NSLocalizedString("好", comment: ""), role: .cancel) { workspace.errorMessage = nil }
        } message: {
            Text(workspace.errorMessage ?? "")
        }
    }
}
