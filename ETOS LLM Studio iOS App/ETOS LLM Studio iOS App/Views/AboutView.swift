import SwiftUI

struct AboutView: View {
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "N/A"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "N/A"
        return "\(version) (Build \(build))"
    }
    
    var body: some View {
        List {
            Section {
                VStack(alignment: .center, spacing: 16) {
                    Image(systemName: "swift")
                        .font(.system(size: 56))
                        .foregroundStyle(.orange)
                    Text("ETOS LLM Studio")
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            
            Section(header: Text("应用信息")) {
                LabeledContent("版本", value: appVersion)
                LabeledContent("开发者", value: "Eric-Terminal")
                LabeledContent("项目地址") {
                    Text("github.com/Eric-Terminal/ETOS-LLM-Studio")
                        .foregroundStyle(.blue)
                }
                LabeledContent("隐私政策") {
                    Text("即将提供").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("关于")
    }
}
