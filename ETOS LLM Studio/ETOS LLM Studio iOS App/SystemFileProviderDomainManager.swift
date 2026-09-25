// ============================================================================
// SystemFileProviderDomainManager.swift
// ETOS LLM Studio iOS App
// ============================================================================

import Combine
import ETOSCore
import FileProvider
import Foundation
import UIKit

@MainActor
enum SystemFileProviderDomainManager {
    private static let identifier = NSFileProviderDomainIdentifier("com.ericterminal.els.workspace")
    private static var observers: Set<AnyCancellable> = []
    private static var registrationInFlight = false
    private static var activeDomain: NSFileProviderDomain?
    private static var domain: NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: identifier,
            displayName: NSLocalizedString("ETOS 工作区", comment: "File Provider domain name")
        )
    }

    static func activate() {
        if observers.isEmpty {
            for name in [UIApplication.didBecomeActiveNotification, UIApplication.protectedDataDidBecomeAvailableNotification] {
                NotificationCenter.default.publisher(for: name)
                    .sink { _ in Task { @MainActor in activate() } }
                    .store(in: &observers)
            }
            // 离开 App 去“文件”时也刷新一次，涵盖仍在运行的交互终端所做的修改。
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
                .sink { _ in Task { @MainActor in signalChanges() } }
                .store(in: &observers)
            NotificationCenter.default.publisher(for: ETOSSharedWorkspaceFiles.didChangeNotification)
                // 首次变化立即送出，避免后台任务刚完成就挂起；随后合并连续写入。
                .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
                .sink { _ in Task { @MainActor in signalChanges() } }
                .store(in: &observers)
        }
        guard !registrationInFlight else { return }
        registrationInFlight = true
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            Task { @MainActor in
                if let error {
                    registrationInFlight = false
                    recordFailure("查询工作区", error: error)
                    return
                }
                if let existing = domains.first(where: { $0.identifier == identifier }) {
                    registrationInFlight = false
                    // 尊重用户在“文件”中关闭入口的选择；域存在不代表当前已启用。
                    activeDomain = existing.userEnabled ? existing : nil
                    if !existing.userEnabled {
                        AppLogCenter.shared.logDeveloper(
                            category: "文件工作区", action: "检查入口", message: "系统文件入口当前未启用。"
                        )
                    }
                    signalChanges()
                    return
                }
                let newDomain = domain
                NSFileProviderManager.add(newDomain) { error in
                    Task { @MainActor in
                        registrationInFlight = false
                        if let error {
                            recordFailure("注册工作区", error: error)
                            return
                        }
                        activeDomain = newDomain
                        signalChanges()
                    }
                }
            }
        }
    }

    /// Agent 或 Linux 工作区发布新文件后，按系统增量协议唤醒现有枚举器。
    static func signalChanges() {
        guard let activeDomain, let manager = NSFileProviderManager(for: activeDomain) else { return }
        manager.signalEnumerator(for: .workingSet) { error in
            if let error { Task { @MainActor in recordFailure("刷新工作区", error: error) } }
        }
        manager.signalEnumerator(for: .rootContainer) { error in
            if let error { Task { @MainActor in recordFailure("刷新根目录", error: error) } }
        }
    }

    private static func recordFailure(_ action: String, error: Error) {
        let error = error as NSError
        AppLogCenter.shared.logDeveloper(
            level: .error,
            category: "文件工作区",
            action: action,
            message: error.localizedDescription,
            payload: ["错误域": error.domain, "错误码": String(error.code)]
        )
    }
}
