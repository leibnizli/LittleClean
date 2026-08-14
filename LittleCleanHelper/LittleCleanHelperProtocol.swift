import Foundation

enum LittleCleanHelperConst {
    static let machServiceName = "dev.arayofsunshine.LittleClean.helper"
    static let launchdPlistName = "dev.arayofsunshine.LittleClean.helper.plist"
    static let appBundleIdentifier = "dev.arayofsunshine.LittleClean"
    static let teamIdentifier = "XTWM4R2294"
}

@objc nonisolated protocol LittleCleanHelperProtocol {
    func removePath(_ path: String, withReply reply: @escaping (Bool, String?) -> Void)
    func movePath(_ path: String, to destination: String, withReply reply: @escaping (Bool, String?) -> Void)
}
