import Combine
import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("发送来源的真实输入区边界", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct ChatSendFlightComposerLayoutTests {
    enum Scenario: CaseIterable, Sendable {
        case expandedFirstLine
        case longDraft
        case attachment
    }

    enum UpperContent: CaseIterable, Sendable {
        case audio
        case suggestions
    }

    @Test("键盘高度预算内附件和建议不与展开编辑器重叠", arguments: ["capsule", "adaptive", "card"], UpperContent.allCases)
    func expandedComposerKeepsUpperContentVisible(style: String, upperContent: UpperContent) async throws {
        let config = AppConfigStore.shared
        await config.waitForPersistentStoreLoaded()
        let originalStyle = config.chatComposerStyle
        let originalBackground = config.currentBackgroundImage
        let originalSlashCommands = config.enableSlashCommands
        config.chatComposerStyle = style
        config.enableSlashCommands = true
        do {
            defer {
                config.chatComposerStyle = originalStyle
                config.currentBackgroundImage = originalBackground
                config.enableSlashCommands = originalSlashCommands
            }
            let service = ChatService()
            await service.waitForInitialPersistenceStateIfNeeded()
            let viewModel = ChatViewModel(chatService: service)
            await viewModel.globalSystemPromptReloadTask?.value
            await viewModel.conversationMemoryReloadTask?.value
            viewModel.cancellables.removeAll()
            // 有效的单声道 PCM，避免播放器失败提示改变待验证音频卡的布局。
            var audioData = Data([
                0x52, 0x49, 0x46, 0x46, 0x64, 0x06, 0, 0,
                0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20,
                0x10, 0, 0, 0, 1, 0, 1, 0, 0x40, 0x1f, 0, 0,
                0x80, 0x3e, 0, 0, 2, 0, 0x10, 0,
                0x64, 0x61, 0x74, 0x61, 0x40, 0x06, 0, 0
            ])
            audioData.append(Data(repeating: 0, count: 1600))
            let audio = AudioAttachment(data: audioData, mimeType: "audio/wav", format: "wav", fileName: "布局试听.wav")
            if upperContent == .audio { viewModel.pendingAudioAttachment = audio }
            let draft = upperContent == .audio
                ? (1...8).map { "第 \($0) 行：附件与正文同时保留，缩短的编辑器仍能阅读所有输入。" }.joined(separator: "\n")
                : "/"
            let controller = ChatSendFlightController()
            let sources = ChatSendFlightSources()
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 500)
            let host = UIHostingController(rootView: ComposerHost(
                viewModel: viewModel, controller: controller, sources: sources,
                draft: draft, startsExpanded: style != "card", availableHeight: 360
            ))
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            let surface = UIView(frame: window.bounds)
            surface.isUserInteractionEnabled = false
            window.addSubview(surface)
            defer {
                controller.cancel()
                window.isHidden = true
                window.rootViewController = nil
            }
            // 只等待真实挂载和异步字体/音频准备，不以强制布局推动最终断言。
            let deadline = ContinuousClock.now + .seconds(5)
            var audioCapture: ChatSendFlightCapture?
            while ContinuousClock.now < deadline {
                if upperContent == .audio {
                    audioCapture = sources.capture(in: surface, ids: [.audio(audio.id)]).first
                }
                if editor(in: host.view, containing: draft) != nil,
                   let outer = controller.composerAnchor,
                   let content = controller.composerContentAnchor,
                   outer.window === window, content.window === window,
                   outer.bounds.height > content.bounds.height + 40,
                   upperContent != .audio || audioCapture != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let editor = try #require(editor(in: host.view, containing: draft))
            let outer = try #require(controller.composerAnchor)
            let content = try #require(controller.composerContentAnchor)
            let outerFrame = outer.convert(outer.bounds, to: surface)
            let contentFrame = content.convert(content.bounds, to: surface)
            let editorFrame = editor.convert(editor.bounds, to: surface)
            #expect(outerFrame.height <= 360.5)
            #expect(outerFrame.minY >= host.view.safeAreaInsets.top - 0.5)
            #expect(contentFrame.minY > outerFrame.minY + 40)
            #expect(editorFrame.minY >= contentFrame.minY - 0.5)
            #expect(editorFrame.maxY <= contentFrame.maxY + 0.5)
            #expect(contentFrame.maxY <= outerFrame.maxY + 0.5)
            if upperContent == .audio {
                let capture = try #require(audioCapture)
                #expect(capture.frame.minY >= outerFrame.minY - 0.5)
                #expect(capture.frame.maxY < contentFrame.minY)
                if style != "card" {
                    let textView = try #require(editor as? UITextView)
                    #expect(textView.isScrollEnabled)
                    #expect(textView.contentSize.height > textView.bounds.height)
                }
            } else {
                // 至少保留一整行建议及兄弟间距，不能只把未显示的建议状态算作成功。
                #expect(contentFrame.minY - outerFrame.minY >= 60 - 0.5)
            }
        } catch {
            await config.flushPendingWrites()
            throw error
        }
        await config.flushPendingWrites()
    }

    @Test("真实输入框展开和附件都限制来源离场边界", arguments: ["capsule", "adaptive", "card"], Scenario.allCases)
    func realComposerBoundsDriveDeparture(style: String, scenario: Scenario) async throws {
        let config = AppConfigStore.shared
        await config.waitForPersistentStoreLoaded()
        let originalStyle = config.chatComposerStyle
        let originalBackground = config.currentBackgroundImage
        config.chatComposerStyle = style
        do {
            defer {
                config.chatComposerStyle = originalStyle
                config.currentBackgroundImage = originalBackground
            }
            let service = ChatService()
            await service.waitForInitialPersistenceStateIfNeeded()
            let viewModel = ChatViewModel(chatService: service)
            await viewModel.globalSystemPromptReloadTask?.value
            await viewModel.conversationMemoryReloadTask?.value
            viewModel.cancellables.removeAll()

            let draft: String
            switch scenario {
            case .expandedFirstLine: draft = "展开框首行"
            case .longDraft: draft = (1...80).map { "第 \($0) 行：真实滚动片段。" }.joined(separator: "\n")
            case .attachment: draft = ""
            }
            let file = FileAttachment(data: Data("边界".utf8), mimeType: "text/plain", fileName: "边界测试.txt")
            if scenario == .attachment { viewModel.pendingFileAttachments = [file] }
            let sourceID: ChatSendPresentationSource = scenario == .attachment ? .file(file.id) : .text
            let controller = ChatSendFlightController()
            let sources = ChatSendFlightSources()
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            let host = UIHostingController(rootView: ComposerHost(
                viewModel: viewModel, controller: controller, sources: sources,
                draft: draft, startsExpanded: style != "card" && scenario != .attachment
            ))
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            // 只在初次挂载排布，之后依靠真实 Composer 更新和既有文本控件的滚动。
            host.view.layoutIfNeeded()
            let surface = UIView(frame: window.bounds)
            surface.isUserInteractionEnabled = false
            window.addSubview(surface)
            controller.attach(to: surface)
            defer {
                controller.cancel()
                window.isHidden = true
                window.rootViewController = nil
            }

            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if let editor = editor(in: host.view, containing: draft),
                   editor.bounds.height > 1,
                   controller.composerAnchor?.window === window,
                   controller.composerContentAnchor?.window === window,
                   controller.viewportAnchor?.window === window {
                    if scenario != .longDraft || style == "card"
                        || (editor as? UITextView).map({ $0.contentSize.height > $0.bounds.height + 100 }) == true {
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let editor = try #require(editor(in: host.view, containing: draft))
            let outerAnchor = try #require(controller.composerAnchor)
            let contentAnchor = try #require(controller.composerContentAnchor)
            try #require(outerAnchor.window === window && contentAnchor.window === window)
            let outerFrame = outerAnchor.convert(outerAnchor.bounds, to: surface)
            let contentFrame = contentAnchor.convert(contentAnchor.bounds, to: surface)

            if scenario == .longDraft, style != "card" {
                let textView = try #require(editor as? UITextView)
                try #require(textView.contentSize.height > textView.bounds.height + 100)
                textView.setContentOffset(CGPoint(
                    x: textView.contentOffset.x,
                    y: textView.contentSize.height - textView.bounds.height
                ), animated: false)
                try await Task.sleep(for: .milliseconds(40))
                try #require(textView.contentOffset.y > 100)
            }

            var captures: [ChatSendFlightCapture] = []
            let captureDeadline = ContinuousClock.now + .seconds(3)
            while captures.isEmpty, ContinuousClock.now < captureDeadline {
                captures = sources.capture(in: surface, ids: [sourceID])
                if captures.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            }
            let capture = try #require(captures.first)
            let departure = try #require(controller.departureBounds)
            #expect(departure.maxY <= outerFrame.minY + 0.5)
            #expect(departure.maxY <= contentFrame.minY + 0.5)
            #expect(capture.frame.maxY > departure.maxY + 1)

            if scenario == .attachment {
                // 附件处在实际输入框上方；只移动旧锚点到输入框会重新得到零离场位移。
                #expect(capture.frame.maxY <= contentFrame.minY + 0.5)
                #expect(departure.maxY <= capture.frame.minY + 0.5)
            } else if style != "card" {
                #expect(abs(outerFrame.height - 66) < 1)
                #expect(contentFrame.minY < outerFrame.minY - 80)
                #expect(editor.bounds.height > 100)
                if scenario == .expandedFirstLine {
                    // 首行本来就高于旧占位锚点，这一断言区分真实 overlay 与手工高度夹具。
                    #expect(capture.frame.maxY < outerFrame.minY)
                } else {
                    #expect(capture.contentVerticalPosition > 0.9)
                    #expect(capture.frame.height <= editor.bounds.height + 0.5)
                }
            } else {
                #expect(abs(contentFrame.minY - outerFrame.minY) < 1)
                #expect(contentFrame.height > editor.bounds.height)
            }

            let started = CACurrentMediaTime()
            controller.begin(
                id: UUID(), captures: captures, response: 0.2, damping: 1, backgrounds: [:], at: started,
                onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in },
                onHandoff: { _, _ in true }, onCompletion: {}
            )
            let flying = try #require(capture.content.superview)
            // 中心与尺寸重组会产生浮点尾差，不能将其误判为起始位置跳变。
            #expect(abs(flying.frame.minX - capture.frame.minX) < 1e-6)
            #expect(abs(flying.frame.minY - capture.frame.minY) < 1e-6)
            #expect(abs(flying.frame.width - capture.frame.width) < 1e-6)
            #expect(abs(flying.frame.height - capture.frame.height) < 1e-6)
            // 尚无身份/落点时也必须已离开输入区；不调用发送、布局刷新或网络来推动此断言。
            controller.advance(at: started + 0.15)
            #expect(flying.frame.maxY < capture.frame.maxY - 1)
            controller.advance(at: started + 1.2)
            #expect(controller.isActive)
            #expect(abs(flying.frame.maxY - departure.maxY) < 0.5)
        } catch {
            await config.flushPendingWrites()
            throw error
        }
        await config.flushPendingWrites()
    }

    private func editor(in view: UIView, containing draft: String) -> UIView? {
        if let textView = view as? UITextView, textView.isEditable, textView.text == draft { return textView }
        if let textField = view as? UITextField, textField.text == draft { return textField }
        for child in view.subviews {
            if let editor = editor(in: child, containing: draft) { return editor }
        }
        return nil
    }
}

@MainActor
private struct ComposerHost: View {
    @ObservedObject var viewModel: ChatViewModel
    let controller: ChatSendFlightController
    let sources: ChatSendFlightSources
    let draft: String
    let startsExpanded: Bool
    var availableHeight: CGFloat = .infinity
    @FocusState private var focused: Bool

    var body: some View {
        Color.clear
            .background(ChatSendFlightLayoutAnchor(controller: controller, region: .viewport))
            .safeAreaInset(edge: .bottom) {
                // 复用生产的占位与 overlay，不用 UIView 人为指定输入框高度。
                VStack(spacing: 0) {
                    TelegramMessageComposer(
                        submissionState: viewModel.sendSubmissionState,
                        sendFlightController: controller,
                        text: .constant(draft), isRequestControlsExpanded: .constant(false),
                        localAgentMode: .constant(.chat), sendAction: { false }, stopAction: {},
                        slashCommandAction: { _ in }, focus: $focused,
                        availableHeight: availableHeight,
                        isExpandedComposer: startsExpanded
                    )
                }
                .background(ChatSendFlightLayoutAnchor(controller: controller, region: .composer))
            }
            .environmentObject(viewModel)
            .environment(\.chatSendFlightSources, sources)
    }
}
