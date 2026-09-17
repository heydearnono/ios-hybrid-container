import Foundation

/// 屏上与日志里要打印的几项，一处读取。取值本身来自 Info.plist，即 `project.yml`。
enum AppMetadata {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "—"

    static let version = string(forInfoKey: "CFBundleShortVersionString")

    static let displayName = string(forInfoKey: "CFBundleDisplayName")

    static let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString

    /// 先读本地化的那份，读不到才退到 Info.plist 本体 —— 设备语言是中文时
    /// `CFBundleDisplayName` 应该拿到「螃蟹」，屏上顺带把这件事显示出来。
    private static func string(forInfoKey key: String) -> String {
        if let localized = Bundle.main.localizedInfoDictionary?[key] as? String {
            return localized
        }
        return Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "—"
    }
}
