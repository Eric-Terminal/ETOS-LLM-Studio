import Testing
import Foundation
@testable import Shared

@Suite("Worldbook Model Compatibility Tests")
struct WorldbookModelCompatibilityTests {

    @Test("ChatSession decodes lorebookIds alias")
    func testChatSessionDecodesLorebookIdsAlias() throws {
        let id = UUID()
        let lorebookID = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "测试会话",
          "lorebookIds": ["\(lorebookID.uuidString)"]
        }
        """

        let data = try #require(json.data(using: .utf8))
        let decoder = JSONDecoder()
        let session = try decoder.decode(ChatSession.self, from: data)

        #expect(session.id == id)
        #expect(session.lorebookIDs == [lorebookID])
    }

    @Test("ChatSession encodes lorebookIDs and worldbookIDs for compatibility")
    func testChatSessionEncodeCompatibilityKeys() throws {
        let lorebookID = UUID()
        let session = ChatSession(id: UUID(), name: "测试", lorebookIDs: [lorebookID])

        let encoder = JSONEncoder()
        let data = try encoder.encode(session)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let lorebookIDs = payload["lorebookIDs"] as? [String]
        let worldbookIDs = payload["worldbookIDs"] as? [String]
        #expect(lorebookIDs == [lorebookID.uuidString])
        #expect(worldbookIDs == [lorebookID.uuidString])
    }
}
