import CryptoKit
import Foundation

struct FeedbackDeviceIdentity: Sendable {
    let deviceID: String
    let token: String

    init(secret: Data) {
        deviceID = SHA256.hash(data: secret).map { String(format: "%02x", $0) }.joined()
        token = secret.map { String(format: "%02x", $0) }.joined()
    }
}

/// 安装级凭据只保存在应用沙盒，排除备份与同步；删除本地数据后不恢复旧身份。
actor FeedbackDeviceIdentityStore {
    static let shared = FeedbackDeviceIdentityStore()
    private var cached: FeedbackDeviceIdentity?
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FeedbackDevice", isDirectory: true)
    }

    func identity() throws -> FeedbackDeviceIdentity {
        if let cached { return cached }
        do {
            let file = directory.appendingPathComponent("credential")
            let secret: Data
            do {
                secret = try Data(contentsOf: file)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                var storageDirectory = directory
                try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try storageDirectory.setResourceValues(values)
                secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                #if os(iOS) || os(watchOS)
                try secret.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try secret.write(to: file, options: .atomic)
                #endif
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            // 读失败或内容损坏时不要覆盖身份，否则已有反馈会与后台留言失联。
            guard secret.count == 32 else { throw DeviceMessageError.identityUnavailable }
            let identity = FeedbackDeviceIdentity(secret: secret)
            cached = identity
            return identity
        } catch {
            throw DeviceMessageError.identityUnavailable
        }
    }
}
