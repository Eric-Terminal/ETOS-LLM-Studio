import Foundation
import Testing
#if os(iOS) || os(watchOS)
import AVFAudio
#endif
@testable import ETOSCore

struct PromptMacroEnvironmentTests {
    @Test("音量和亮度与电量保持相同百分比单位，异常值不伪装成零")
    func percentageReadingsKeepUnitsAndUnknownState() {
        #expect(PromptMacroEnvironment.percentageValue(0) == "0")
        #expect(PromptMacroEnvironment.percentageValue(0.625) == "63")
        #expect(PromptMacroEnvironment.percentageValue(1) == "100")
        for value in [Float(-1), 1.1, .nan, .infinity] {
            #expect(PromptMacroEnvironment.percentageValue(value) == "unknown")
        }
    }

    #if os(iOS) || os(watchOS)
    @Test("音频路由保留多端口顺序，蓝牙不误判为耳机，未来类型保留系统标识")
    func audioRoutesPreserveReportedPorts() {
        let outputs = PromptMacroAudioEnvironment.routeValues([
            (.builtInSpeaker, "手机扬声器"), (.bluetoothA2DP, "桌面音箱"), (.airPlay, "客厅")
        ])
        #expect(outputs.types == "speaker, bluetooth, airplay")
        #expect(outputs.names == "手机扬声器, 桌面音箱, 客厅")
        let input = PromptMacroAudioEnvironment.routeValues([(.builtInMic, "  内置麦克风  ")])
        #expect(input.types == "microphone")
        #expect(input.names == "内置麦克风")
        let future = PromptMacroAudioEnvironment.routeValues([(.init(rawValue: "FuturePort"), "")])
        #expect(future.types == "FuturePort")
        #expect(future.names == "unknown")
    }

    @Test("没有报告音频路由时明确表示 none")
    func emptyAudioRouteHasNoReportedDevice() {
        let route = PromptMacroAudioEnvironment.routeValues([])
        #expect(route.types == "none")
        #expect(route.names == "none")
    }
    #endif

    @Test("存储使用十进制 GB，两位小数与字节、剩余百分比一致")
    func storageUnitsRemainConsistent() {
        let values = PromptMacroResourceEnvironment.storageValues(freeBytes: 32_000_000_000, totalBytes: 128_000_000_000)
        #expect(values["storage_free_bytes"] == "32000000000")
        #expect(values["storage_total_bytes"] == "128000000000")
        #expect(values["storage_free_gb"] == "32.00")
        #expect(values["storage_total_gb"] == "128.00")
        #expect(values["storage_free_percent"] == "25")
        #expect(PromptMacroResourceEnvironment.gigabytes(1_234_567_890) == "1.23")
    }

    @Test("区分存储已满、读取失败与无效总容量")
    func storageDoesNotInventMissingCapacity() {
        let full = PromptMacroResourceEnvironment.storageValues(freeBytes: 0, totalBytes: 1_000_000_000)
        #expect(full["storage_free_bytes"] == "0")
        #expect(full["storage_free_percent"] == "0")
        let missing = PromptMacroResourceEnvironment.storageValues(freeBytes: nil, totalBytes: nil)
        #expect(missing.values.allSatisfy { $0 == "unknown" })
        let invalid = PromptMacroResourceEnvironment.storageValues(freeBytes: -1, totalBytes: 0)
        #expect(invalid.values.allSatisfy { $0 == "unknown" })
        let inconsistent = PromptMacroResourceEnvironment.storageValues(freeBytes: 2, totalBytes: 1)
        #expect(inconsistent["storage_free_percent"] == "unknown")
    }

    @Test("屏幕尺寸以点表示，缩放倍率与不支持的亮度分别保留")
    func screenUnitsAndUnavailableBrightnessRemainExplicit() {
        let watch = PromptMacroScreenEnvironment.values(
            bounds: CGRect(x: 0, y: 0, width: 208, height: 248), scale: 2, brightness: nil
        )
        #expect(watch["screen_width"] == "208")
        #expect(watch["screen_height"] == "248")
        #expect(watch["screen_scale"] == "2.0")
        #expect(watch["screen_brightness"] == "unknown")
        let phone = PromptMacroScreenEnvironment.values(
            bounds: CGRect(x: 0, y: 0, width: 402, height: 874), scale: 3, brightness: 0.8
        )
        #expect(phone["screen_brightness"] == "80")
    }

    @Test("新增设备宏可展开且三括号不会触发相应采集，页面向导包含完整宏名称")
    func deviceMacroNamesMatchResolverAndGuideDocumentation() throws {
        let names = PromptMacroResolver.audioNames.union(PromptMacroResolver.screenNames)
            .union(PromptMacroResolver.storageNames).union(PromptMacroResolver.hardwareNames)
        let document = try #require(GuideDocumentCatalog.documents.first { $0.id == "settings-core" })
        for name in names {
            #expect(PromptMacroResolver.render("{{\(name)}}", values: [name: "sample"]) == "sample")
            #expect(PromptMacroResolver.render("{{{\(name)}}}", values: [name: "sample"]) == "{{\(name)}}")
            #expect(PromptMacroResolver.referencedNames(in: ["{{{\(name)}}}"]).isEmpty)
        }
        for name in PromptMacroResolver.supportedNames {
            #expect(document.content.contains(name))
        }
    }
}
