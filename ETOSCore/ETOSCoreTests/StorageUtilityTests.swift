import Foundation
import Testing
@testable import ETOSCore

@Suite("存储大小格式化测试")
struct StorageUtilityTests {
    @Test("传输进度为整数兆字节时保留一位小数")
    func transferSizeKeepsFractionDigitForWholeMegabytes() {
        let result = StorageUtility.formatTransferSize(17_000_000)

        #expect(result.range(of: #"17[.,]0"#, options: .regularExpression) != nil)
    }

    @Test("普通文件大小格式化行为保持不变")
    func regularSizeDoesNotForceFractionPadding() {
        let result = StorageUtility.formatSize(17_000_000)

        #expect(result.range(of: #"17[.,]0"#, options: .regularExpression) == nil)
    }
}

@Suite("传输百分比测试")
struct TransferProgressPercentageTests {
    @Test("上传在服务端确认前最高显示百分之九十九")
    func uploadWaitsForConfirmationBeforeShowingOneHundredPercent() {
        let sending = SyncPackageUploadProgress(bytesSent: 100_000_000, totalBytes: 100_000_000)
        let confirmed = SyncPackageUploadProgress(
            bytesSent: 100_000_000,
            totalBytes: 100_000_000,
            isConfirmedComplete: true
        )

        #expect(sending.displayPercentage == 99)
        #expect(confirmed.displayPercentage == 100)
    }

    @Test("下载接近完成时不会提前显示百分之百")
    func downloadDoesNotRoundUpToOneHundredPercent() {
        let progress = SyncPackageDownloadProgress(bytesReceived: 99_900_000, totalBytes: 100_000_000)

        #expect(progress.displayPercentage == 99)
    }
}
