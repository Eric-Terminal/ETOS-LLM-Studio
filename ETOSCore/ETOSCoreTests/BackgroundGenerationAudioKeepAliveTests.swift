import Foundation
import Testing
@testable import ETOSCore

@Suite("后台生成音频保活测试")
struct BackgroundGenerationAudioKeepAliveTests {
    @Test("音频保活默认关闭且音量限制在可听范围")
    func defaultsAndVolumeBounds() {
        #expect(AppConfigKey.backgroundGenerationAudioKeepAliveEnabled.defaultValue == .bool(false))
        #expect(
            AppConfigKey.backgroundGenerationAudioKeepAliveVolume.defaultValue
                == .real(BackgroundGenerationAudioKeepAliveSettings.defaultVolume)
        )
        #expect(
            BackgroundGenerationAudioKeepAliveSettings.normalizedVolume(0)
                == BackgroundGenerationAudioKeepAliveSettings.minimumVolume
        )
        #expect(
            BackgroundGenerationAudioKeepAliveSettings.normalizedVolume(2)
                == BackgroundGenerationAudioKeepAliveSettings.maximumVolume
        )
    }

    @Test("等待音数据包含完整的循环 WAV")
    func buildsLoopingWAVData() {
        let data = BackgroundGenerationWaitAudioFactory.makeWAVData()
        let expectedPCMByteCount = Int(
            Double(BackgroundGenerationWaitAudioFactory.sampleRate)
                * BackgroundGenerationWaitAudioFactory.duration
        ) * MemoryLayout<Int16>.size

        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.dropFirst(8).prefix(4), encoding: .ascii) == "WAVE")
        #expect(data.count == 44 + expectedPCMByteCount)
    }
}
