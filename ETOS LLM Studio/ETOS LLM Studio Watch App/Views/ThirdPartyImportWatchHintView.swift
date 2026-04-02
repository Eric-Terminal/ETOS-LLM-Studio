// ============================================================================
// ThirdPartyImportWatchHintView.swift
// ============================================================================
// 第三方导入引导页 (watchOS)
// - 手表端只负责提示用户去 iPhone 完成导入
// ============================================================================

import SwiftUI

struct ThirdPartyImportWatchHintView: View {
    var body: some View {
        List {
            Section {
                Label("请在 iPhone 上导入", systemImage: "iphone")
                    .etFont(.headline)
                Text("第三方数据导入需要文件选择器与本地解析，当前请在 iPhone App 的「设置 → 拓展功能 → 第三方导入」完成。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "1.circle")
                        .foregroundStyle(.secondary)
                    Text("在 iPhone 端打开「第三方导入」。")
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "2.circle")
                        .foregroundStyle(.secondary)
                    Text("选择来源并导入导出文件。")
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "3.circle")
                        .foregroundStyle(.secondary)
                    Text("导入完成后会自动同步到手表。")
                }
            } header: {
                Text("操作步骤")
            }
        }
        .navigationTitle("第三方导入")
    }
}
