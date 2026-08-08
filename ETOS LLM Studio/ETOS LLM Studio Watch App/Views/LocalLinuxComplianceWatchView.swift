// ============================================================================
// LocalLinuxComplianceWatchView.swift
// ============================================================================
// ETOS LLM Studio
// ============================================================================

import ETOSCore
import SwiftUI

struct LocalLinuxComplianceWatchView: View {
    @State private var seedSummary = NSLocalizedString("正在读取内置系统清单…", comment: "Watch loading Linux compliance summary")

    var body: some View {
        List {
            Section(NSLocalizedString("内置系统", comment: "Watch bundled Linux system section")) {
                Text(seedSummary)
                    .font(.caption2)
            }
            Section(NSLocalizedString("许可与源码", comment: "Watch Linux licenses and source section")) {
                ForEach(LocalLinuxComplianceDocument.allCases) { document in
                    NavigationLink(document.displayName) {
                        LocalLinuxComplianceWatchDocumentView(document: document)
                    }
                }
            }
            Text(NSLocalizedString("这些文件与当前 App 内置的 RootFS 一起签名交付。", comment: "Watch Linux compliance footer"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(NSLocalizedString("许可与源码", comment: "Watch Linux compliance title"))
        .task { await loadSeedSummary() }
    }

    private func loadSeedSummary() async {
        seedSummary = await Task.detached(priority: .utility) {
            do {
                let seed = try LocalLinuxSeedResource.load()
                return String(
                    format: NSLocalizedString("Alpine %@\n%@ · %llu 个文件\nSHA-256：%@", comment: "Watch bundled Linux seed summary"),
                    seed.metadata.alpineVersion,
                    seed.metadata.guestArchitecture,
                    seed.metadata.entryCount,
                    seed.metadata.archiveSHA256
                )
            } catch {
                return error.localizedDescription
            }
        }.value
    }
}

private struct LocalLinuxComplianceWatchDocumentView: View {
    let document: LocalLinuxComplianceDocument
    @State private var content = NSLocalizedString("正在读取…", comment: "Watch loading Linux compliance document")

    var body: some View {
        ScrollView {
            Text(content)
                .font(.caption2.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(document.displayName)
        .task {
            content = await Task.detached(priority: .utility) {
                guard let url = document.resourceURL() else {
                    return NSLocalizedString("找不到这份随包资源。", comment: "Watch missing Linux compliance document")
                }
                do {
                    return try String(contentsOf: url, encoding: .utf8)
                } catch {
                    return error.localizedDescription
                }
            }.value
        }
    }
}
