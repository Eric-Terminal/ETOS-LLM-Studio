import Combine
import ETOSCore
import SwiftUI

@MainActor
struct MacReadAloudButton: View {
    @ObservedObject var model: MacTTSModel
    let message: ChatMessage
    let sessionID: UUID?
    let isActive: Bool
    var iconOnly = false
    @State private var isReading = false

    var body: some View {
        Button {
            if let sessionID { model.read(message, sessionID: sessionID) }
        } label: {
            if iconOnly {
                Image(systemName: isReading ? "stop.fill" : "speaker.wave.2")
                    .accessibilityLabel(isReading ? NSLocalizedString("停止朗读", comment: "") : NSLocalizedString("朗读消息", comment: ""))
            } else {
                Text(isReading ? NSLocalizedString("停止朗读", comment: "") : NSLocalizedString("朗读消息", comment: ""))
            }
        }
        .disabled(!isActive || !model.canPlay || sessionID == nil || !MessageActionBarAvailability.canReadAloud(message))
        .onReceive(model.player.$currentSpeakingMessageID.combineLatest(model.player.$isSpeaking)
            .map { [messageID = message.id] speakingID, speaking in speakingID == messageID && speaking }.removeDuplicates()) { isReading = $0 }
    }
}
