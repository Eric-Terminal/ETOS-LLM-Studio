import Foundation
import Testing
@testable import ETOS_LLM_Studio_App

struct CustomAppIconProfileTests {
    @Test("自定义图标描述文件只包含可移除的 Web Clip")
    func profileContainsExpectedWebClip() throws {
        let iconData = Data([0x89, 0x50, 0x4E, 0x47])
        let profileData = try CustomAppIconProfileBuilder.makeProfile(
            iconPNGData: iconData,
            label: "我的 ETOS",
            profileDescription: "测试描述"
        )

        let propertyList = try PropertyListSerialization.propertyList(
            from: profileData,
            options: [],
            format: nil
        )
        let profile = try #require(propertyList as? [String: Any])
        #expect(profile["PayloadType"] as? String == "Configuration")
        #expect(profile["PayloadIdentifier"] as? String == CustomAppIconProfileBuilder.profileIdentifier)

        let payloads = try #require(profile["PayloadContent"] as? [[String: Any]])
        #expect(payloads.count == 1)
        let webClip = try #require(payloads.first)
        #expect(webClip["PayloadType"] as? String == "com.apple.webClip.managed")
        #expect(webClip["URL"] as? String == CustomAppIconProfileBuilder.appLaunchURL)
        #expect(webClip["Label"] as? String == "我的 ETOS")
        #expect(webClip["Icon"] as? Data == iconData)
        #expect(webClip["IsRemovable"] as? Bool == true)
        #expect(webClip["Precomposed"] as? Bool == true)
        #expect(webClip["FullScreen"] as? Bool == false)
    }

    @Test("空图片不会生成图标描述文件")
    func emptyIconIsRejected() {
        #expect(throws: CustomAppIconProfileError.self) {
            try CustomAppIconProfileBuilder.makeProfile(
                iconPNGData: Data(),
                label: "ETOS",
                profileDescription: "测试描述"
            )
        }
    }
}
