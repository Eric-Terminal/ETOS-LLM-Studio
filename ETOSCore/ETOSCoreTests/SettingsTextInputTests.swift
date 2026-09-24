import Testing
@testable import ETOSCore

struct SettingsTextInputTests {
    @Test("峰谷时间接受 24 小时制与中文冒号，拒绝未完成或越界的时间")
    func validatesTimeText() {
        for (text, expected) in [("00:00", 0), ("23:59", 1439), ("12:30", 750), ("9:05", 545), (" 12：30 \n", 750)] {
            #expect(ModelPricingTimeRangeText.minuteOfDay(from: text) == expected)
        }
        for text in ["", "12", "12:", "12:3", "24:00", "12:60", "-1:00", "+1:00", "12:30:00", "001:00", "noon"] {
            #expect(ModelPricingTimeRangeText.minuteOfDay(from: text) == nil)
        }
    }

    @Test("全天所有分钟可在显示文本和计费分钟值之间无损往返")
    func timeTextRoundTripsEveryMinute() {
        for minute in 0..<1440 {
            #expect(ModelPricingTimeRangeText.minuteOfDay(from: ModelPricingTimeRangeText.displayTime(minuteOfDay: minute)) == minute)
        }
    }

    @Test("自动重试文本允许零与上限，空值、小数和越界值不覆盖已有设置")
    func validatesRetryCountText() {
        for count in ChatRequestRetryPolicy.allowedMaximumRetries {
            #expect(ChatRequestRetryPolicy.maximumRetries(from: " \(count) ") == count)
        }
        for text in ["", " ", "-1", "11", "3.5", "1e1", "+3", "三", "999999999999999999999999"] {
            #expect(ChatRequestRetryPolicy.maximumRetries(from: text) == nil)
        }
    }
}
