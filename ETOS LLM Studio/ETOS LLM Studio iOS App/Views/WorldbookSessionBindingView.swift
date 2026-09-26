import SwiftUI
import ETOSCore

struct WorldbookSessionBindingView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        WorldbookSessionBindingContent(session: $viewModel.currentSession) { id in
            WorldbookDetailView(worldbookID: id)
        } management: {
            WorldbookSettingsView(showsSessionBinding: false)
                .environmentObject(viewModel)
        }
    }
}
