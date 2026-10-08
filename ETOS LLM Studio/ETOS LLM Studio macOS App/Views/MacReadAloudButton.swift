import Combine
import ETOSCore
import SwiftUI

struct MacReadAloudButton: View {
    @ObservedObject var model: MacTTSModel
    let message: ChatMessage
    let sessionID: UUID?
    let isActive: Bool
    @State private var isReading = false

    var body: some View {
        Button(isReading ? NSLocalizedString("停止朗读", comment: "") : NSLocalizedString("朗读消息", comment: "")) {
            if let sessionID { model.read(message, sessionID: sessionID) }
        }
        .disabled(!isActive || !model.canPlay || sessionID == nil || !MessageActionBarAvailability.canReadAloud(message))
        .onReceive(model.player.$currentSpeakingMessageID.combineLatest(model.player.$isSpeaking)
            .map { [messageID = message.id] speakingID, speaking in speakingID == messageID && speaking }.removeDuplicates()) { isReading = $0 }
    }
}
