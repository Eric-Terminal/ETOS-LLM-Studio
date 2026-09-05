import Foundation
#if os(iOS) || os(watchOS)
import AVFAudio
#endif

enum PromptMacroAudioEnvironment {
    static func capture() -> [String: String] {
        #if os(iOS) || os(watchOS)
        // 只读取系统报告的快照，不为宏切换音频类别或激活会话，以免打断正在播放的声音。
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputs = routeValues(route.outputs.map { ($0.portType, $0.portName) })
        let inputs = routeValues(route.inputs.map { ($0.portType, $0.portName) })
        return [
            "volume_level": PromptMacroEnvironment.percentageValue(session.outputVolume),
            "audio_output_type": outputs.types,
            "audio_output_name": outputs.names,
            "audio_input_type": inputs.types,
            "audio_input_name": inputs.names,
            "other_audio_playing": session.isOtherAudioPlaying ? "true" : "false"
        ]
        #else
        return Dictionary(uniqueKeysWithValues: PromptMacroResolver.audioNames.map { ($0, "unknown") })
        #endif
    }

    #if os(iOS) || os(watchOS)
    static func routeValues(_ ports: [(type: AVAudioSession.Port, name: String)]) -> (types: String, names: String) {
        guard !ports.isEmpty else { return ("none", "none") }
        return (
            ports.map { portTypeName($0.type) }.joined(separator: ", "),
            ports.map {
                let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "unknown" : name
            }.joined(separator: ", ")
        )
    }

    private static func portTypeName(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInSpeaker: return "speaker"
        case .builtInReceiver: return "receiver"
        case .headphones: return "headphones"
        case .builtInMic: return "microphone"
        case .headsetMic: return "headset_microphone"
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return "bluetooth"
        case .airPlay: return "airplay"
        case .usbAudio: return "usb"
        case .HDMI: return "hdmi"
        case .lineIn: return "line_in"
        case .lineOut: return "line_out"
        case .carAudio: return "car_audio"
        default: return type.rawValue.isEmpty ? "unknown" : type.rawValue
        }
    }
    #endif
}
