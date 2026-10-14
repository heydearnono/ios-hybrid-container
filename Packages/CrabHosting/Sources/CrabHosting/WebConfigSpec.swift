import Foundation

/// UA 标记的拼接。pro 的取值表:标记 `Crab`、首个版本 `0.1.0`、拼成 `Crab/0.1.0`;形状是
/// `<系统 UA> Crab/<版本>`,**追加不替换**,三端一字不差。
///
/// iOS 走 `configuration.applicationNameForUserAgent`,只需提供 `Crab/<版本>` 这一段,系统 UA 由
/// WebKit 自己接在前面(标记落在 UA 哪个位置由 WebKit 定,见 pro 的「要试出来的」,打印出来逐字比)。
/// 版本从 `CFBundleShortVersionString` 取,不取构建号 / 模块版本。
public enum CrabUserAgent {
    /// UA 标记。取值来自 pro 的取值表,本仓不自定。
    public static let marker = "Crab"

    /// `applicationNameForUserAgent` 要的那一段:`Crab/<版本>`。
    public static func applicationName(version: String) -> String {
        "\(marker)/\(version)"
    }
}

/// 六项配置的**意图取值**。iOS 的框架对象取值在 JVM / 宿主上测不了(没有 Android 那种 stub),
/// 所以这里把「端决定取什么」固化成常量、由单测钉住,写进 `WKWebViewConfiguration` 的那几行再在
/// 模拟器上观察。取值一律照 pro 的六项表,本仓不自定。
///
/// iOS 的落地方式见 `App/CrabWebViewConfig.swift`;有几项 iOS 没有公开开关(DOM storage 一向开、
/// 文件访问靠不用 `file://` 承载、缩放靠 `scrollView` 掐),那几项这里记的是「端要达到的状态」,
/// 不代表存在一个同名开关。
public enum WebConfigSpec {
    /// JavaScript:开。页面靠它跑。
    public static let javaScriptEnabled = true
    /// DOM storage:开。iOS 一向是开的、无公开开关。
    public static let domStorageEnabled = true
    /// 混合内容:不加载任何 http 子资源(取最严)。iOS 靠 `WKContentRuleList` 拦 `^http://`。
    public static let allowsHTTPSubresources = false
    /// 文件访问:关。iOS 无公开开关,靠三端一律不用 `file://` 承载达成。
    public static let fileAccessEnabled = false
    /// 有声媒体自动播放:要求用户手势(静音视频不受影响)。
    public static let audioAutoplayRequiresUserGesture = true
    /// 缩放:关,文字缩放固定 100。iOS 靠 `scrollView` 的 min/maxZoomScale 都设 1;iOS 不跟随系统字号。
    public static let zoomEnabled = false
}
