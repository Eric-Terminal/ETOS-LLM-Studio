import ETOSCore
import SwiftUI

/// 只有控制栏订阅高频播放进度，消息列表和工作区不转发这些变化。
struct MacTTSPlaybackView: View {
    @ObservedObject var model: MacTTSModel
    @ObservedObject private var player: TTSManager
    let isActive: Bool
    init(model: MacTTSModel, isActive: Bool) { self.model = model; self.player = model.player; self.isActive = isActive }

    var body: some View {
        VStack(alignment: .leading) {
            if player.isSpeaking || player.canReplayLastRequest {
                HStack {
                    if player.isSpeaking {
                        Button(player.playbackState.status == .paused ? NSLocalizedString("继续播放", comment: "") : NSLocalizedString("暂停", comment: "")) {
                            if player.playbackState.status == .paused { player.resume() } else { player.pause() }
                        }
                        Button(NSLocalizedString("停止朗读", comment: "")) { model.stop() }
                    }
                    Button(NSLocalizedString("重新朗读", comment: "")) { player.replayLastRequest() }.disabled(!player.canReplayLastRequest)
                    Button(NSLocalizedString("导出音频", comment: "")) { model.exportAudio() }.disabled(!player.canExportLastNetworkAudio)
                }.buttonStyle(.borderless)
                if player.playbackState.duration > 0 {
                    ProgressView(value: player.playbackState.position, total: player.playbackState.duration)
                    HStack {
                        Button(NSLocalizedString("后退 10 秒", comment: "")) { player.seekBy(seconds: -10) }
                        Button(NSLocalizedString("前进 10 秒", comment: "")) { player.seekBy(seconds: 10) }
                        Slider(value: Binding(get: { Double(player.playbackState.speed) }, set: { player.setPlaybackSpeed(Float($0)) }), in: 0.5...2) {
                            Text(NSLocalizedString("播放倍速", comment: ""))
                        }
                    }.buttonStyle(.borderless).disabled(!player.canSeekCurrentAudio)
                }
                if player.playbackState.status == .buffering { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                if let error = player.playbackState.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            if model.isExporting { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }.disabled(!isActive || !model.canPlay)
    }
}
