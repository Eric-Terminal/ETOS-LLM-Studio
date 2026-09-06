// ============================================================================
// SystemFileProviderDomainManager.swift
// ETOS LLM Studio iOS App
// ============================================================================

import FileProvider
import Foundation

enum SystemFileProviderDomainManager {
    private static let identifier = NSFileProviderDomainIdentifier("com.ericterminal.els.workspace")
    private static var domain: NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: identifier,
            displayName: NSLocalizedString("ETOS 工作区", comment: "File Provider domain name")
        )
    }

    static func activate() {
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            guard !domains.contains(where: { $0.identifier == identifier }) else { return }
            NSFileProviderManager.add(domain) { error in
                if let error {
                    NSLog("无法注册 ETOS 工作区：%@", error.localizedDescription)
                }
            }
        }
    }

    /// Agent 或 Linux 工作区发布新文件后，按系统增量协议唤醒现有枚举器。
    static func signalChanges() {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: .workingSet) { error in
            if let error { NSLog("无法刷新 ETOS 工作区：%@", error.localizedDescription) }
        }
        manager.signalEnumerator(for: .rootContainer) { error in
            if let error { NSLog("无法刷新 ETOS 工作区根目录：%@", error.localizedDescription) }
        }
    }
}
