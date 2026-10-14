import Foundation
import WebKit
import CrabHosting

/// M3 的容器配置:六项配置逐项显式、页面开口前注入、UA 追加标记、带 identifier 的持久化 store。
/// **全部在 `WKWebView` 创建之前落定** —— iOS 初始化会拷贝配置对象,创建之后改那个对象对已建实例
/// 无影响(pro 的 M3「要做到什么」,出处 `WKWebView.h`)。
///
/// 承载常量只在 `HostingOrigin` 一处;注入范围判定、scheme 注册都从它派生,这里不另写字面量。
///
/// 方法都标 `@MainActor`:`WKWebViewConfiguration` 及其属性在 SDK 里是主线程隔离的,Swift 6 严格
/// 并发下从非隔离上下文碰它会报错。
enum CrabWebViewConfig {
    /// 带 identifier 的持久化 `WKWebsiteDataStore`(iOS 17,deployment 26.0 已覆盖):既隔离 Cookie、
    /// 又保住 storage 跨启动。pro 要「以承载 scheme 名做 identifier」,但 iOS 17 的
    /// `WKWebsiteDataStore(forIdentifier:)` 取的是 **UUID 不是字符串**,所以落成一个与 scheme 绑定的
    /// 固定 UUID(改 scheme 就该换这个 UUID,等于换一个隔离域)。这条 API 形状是平台事实,待回流 pro。
    static let dataStoreIdentifier = UUID(uuidString: "C7AB0000-0000-5000-A000-000000000001")!

    /// 应用版本,UA 版本段取它(`CFBundleShortVersionString`),不取构建号 / 模块版本。
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 建一个配好的 configuration。handler 的承载根由调用方给(探针与正式承载目录位置不同)。
    @MainActor
    static func makeConfiguration(hostingRoot: URL) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()

        // 1. JavaScript:开。`javaScriptEnabled` 已废弃,改走 `defaultWebpagePreferences`。
        configuration.defaultWebpagePreferences.allowsContentJavaScript = WebConfigSpec.javaScriptEnabled

        // 2. DOM storage:iOS 一向开、无公开开关 —— 不写代码,靠平台默认达成(记在取值 spec 里)。

        // 3. 有声媒体自动播放:要求用户手势。`.audio` 只掐有声,静音视频照旧。
        configuration.mediaTypesRequiringUserActionForPlayback =
            WebConfigSpec.audioAutoplayRequiresUserGesture ? .audio : []

        // 4. UA:追加 `Crab/<版本>`,不替换整串。首选 `applicationNameForUserAgent`,省掉读系统 UA。
        configuration.applicationNameForUserAgent = CrabUserAgent.applicationName(version: appVersion)

        // 5. Cookie 不与原生共享 + storage 跨启动:带 identifier 的持久化 store。
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreIdentifier)

        // 6. 承载 handler:scheme 从 HostingOrigin 派生。
        configuration.setURLSchemeHandler(
            CrabSchemeHandler(root: hostingRoot),
            forURLScheme: HostingOrigin.scheme
        )

        // 7. 页面开口前那段脚本:atDocumentStart + 仅主帧;脚本自身再判 origin(双保险)。
        let injection = WKUserScript(
            source: WebInjection.documentStartScript(origin: HostingOrigin.origin),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(injection)

        return configuration
    }

    /// 混合内容:不加载任何 http 子资源。首选 `WKContentRuleList` 编译一条拦 `^http://` 的规则。
    /// 异步编译,编好后加到 controller 上,所以在 `load` 之前 `await` 它。
    @MainActor
    static func applyHTTPBlockRule(to webView: WKWebView) async {
        guard !WebConfigSpec.allowsHTTPSubresources else { return }
        let rule = #"[{"trigger":{"url-filter":"^http://"},"action":{"type":"block"}}]"#
        let compiled = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "crab-block-http",
            encodedContentRuleList: rule
        )
        if let list = compiled ?? nil {
            webView.configuration.userContentController.add(list)
        }
    }

    /// 缩放:关。iOS 没有公开缩放属性,从 `scrollView` 两个 zoomScale 都掐成 1。创建之后设,是因为
    /// `scrollView` 是 UIKit 那侧的、不在被拷贝的 configuration 里 —— 这也正是差异表要暴露的那一格。
    @MainActor
    static func disableZoom(on webView: WKWebView) {
        guard !WebConfigSpec.zoomEnabled else { return }
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.bouncesZoom = false
    }
}
