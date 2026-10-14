import SwiftUI
import WebKit

/// 加载后生效差异表 · iOS 一列的观察跑。带 `--probe-diff` 启动。
///
/// pro 的三步法:实例 A 加载前设成目标值(基线);实例 B 加载前设成相反值,加载完**再改成目标值不重载**
/// 看变不变,没变就重载再看。iOS 预期多数是「完全不生效」—— 配置对象在初始化时被拷贝,改那份拷贝对
/// 已建实例无影响。真有一格不是「完全不生效」(比如缩放,它在 UIKit 的 `scrollView` 上、不在被拷贝的
/// 配置里)就值得记下来。
///
/// 这里只自动跑清晰可观察的三格:UA、缩放、JavaScript。其余几格(DOM storage 无开关、混合内容需
/// http 源与网络、有声媒体需真实视频素材)不在这里硬凑,结论与依据写在 docs/运行记录/M3.md,核不准的标
/// `[待确认]`,不编。结果落 Documents/diff-result.txt。
struct ProbeDiffView: View {
    @State private var text = "running diff…"

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .task { text = await DiffRunner.run() }
    }
}

/// 等一次导航结束的小 delegate:didFinish / didFail 都唤醒。
@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var cont: CheckedContinuation<Void, Never>?

    func wait(_ webView: WKWebView, load urlString: String) async {
        webView.navigationDelegate = self
        webView.load(URLRequest(url: URL(string: urlString)!))
        await withCheckedContinuation { cont = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume() }

    private func resume() { cont?.resume(); cont = nil }
}

@MainActor
enum DiffRunner {
    static func run() async -> String {
        var lines: [String] = ["# 加载后生效差异表 · iOS 一列（三步法，两实例）"]
        lines.append(await uaRow())
        lines.append(await zoomRow())
        lines.append(await javaScriptRow())
        let text = lines.joined(separator: "\n") + "\n"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? text.write(to: docs.appendingPathComponent("diff-result.txt"), atomically: true, encoding: .utf8)
        return text
    }

    private static func js(_ wv: WKWebView, _ code: String) async -> String {
        let v = try? await wv.evaluateJavaScript(code)
        return (v as? String) ?? String(describing: v ?? "nil")
    }

    private static let page = "data:text/html,<html><head></head><body>x</body></html>"

    // UA:标记落在配置对象上,配置被拷贝 → 事后改预期完全不生效。
    private static func uaRow() async -> String {
        let waiterA = LoadWaiter()
        let cfgA = WKWebViewConfiguration()
        cfgA.applicationNameForUserAgent = "Crab/0.1.0"
        let a = WKWebView(frame: .zero, configuration: cfgA)
        await waiterA.wait(a, load: page)
        let uaA = await js(a, "navigator.userAgent")

        let waiterB = LoadWaiter()
        let cfgB = WKWebViewConfiguration() // 相反值:不设标记
        let b = WKWebView(frame: .zero, configuration: cfgB)
        await waiterB.wait(b, load: page)
        let uaB1 = await js(b, "navigator.userAgent")
        b.configuration.applicationNameForUserAgent = "Crab/0.1.0" // 改那份拷贝
        await waiterB.wait(b, load: page) // 重载
        let uaB2 = await js(b, "navigator.userAgent")

        let aHas = uaA.contains("Crab/0.1.0")
        let b2Has = uaB2.contains("Crab/0.1.0")
        let verdict = b2Has ? "重载后生效" : "完全不生效"
        return "UA\t\(verdict)\t基线A含标记=\(aHas) 实例B改后重载含标记=\(b2Has)"
    }

    // 缩放:scrollView 是 UIKit 那侧的,不在被拷贝的 configuration 里 → 预期立即生效(本列的例外)。
    private static func zoomRow() async -> String {
        let waiter = LoadWaiter()
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        await waiter.wait(wv, load: page)
        wv.scrollView.minimumZoomScale = 1
        wv.scrollView.maximumZoomScale = 3 // 相反值:允许放大
        let before = wv.scrollView.maximumZoomScale
        wv.scrollView.maximumZoomScale = 1 // 事后改成目标值,不重载
        let after = wv.scrollView.maximumZoomScale
        let verdict = (before != after) ? "立即生效" : "完全不生效"
        return "缩放\t\(verdict)\tmaxZoom 改前=\(before) 改后=\(after)（不重载）"
    }

    // JavaScript:allowsContentJavaScript 在被拷贝的 configuration 上 → 事后改预期完全不生效。
    // 用页面脚本置一个 window 全局、再由原生 evaluateJavaScript 读(evaluateJavaScript 不受该开关影响,
    // 所以读得到「内容脚本到底跑没跑」),比 webView.title 在 data: 页上可靠。
    private static func javaScriptRow() async -> String {
        let jsPage = "data:text/html,<html><head></head><body><script>window.__JSRAN__=true</script></body></html>"
        let probe = "(window.__JSRAN__ === true) ? '1' : '0'"

        let waiterA = LoadWaiter()
        let cfgA = WKWebViewConfiguration()
        cfgA.defaultWebpagePreferences.allowsContentJavaScript = true
        let a = WKWebView(frame: .zero, configuration: cfgA)
        await waiterA.wait(a, load: jsPage)
        let aRan = (await js(a, probe)) == "1"

        let waiterB = LoadWaiter()
        let cfgB = WKWebViewConfiguration()
        cfgB.defaultWebpagePreferences.allowsContentJavaScript = false // 相反值
        let b = WKWebView(frame: .zero, configuration: cfgB)
        await waiterB.wait(b, load: jsPage)
        let bRanBefore = (await js(b, probe)) == "1"
        b.configuration.defaultWebpagePreferences.allowsContentJavaScript = true // 改拷贝
        await waiterB.wait(b, load: jsPage) // 重载
        let bRanAfter = (await js(b, probe)) == "1"

        let verdict = bRanAfter ? "重载后生效" : "完全不生效"
        return "JavaScript\t\(verdict)\t基线A脚本跑=\(aRan) 实例B改后重载脚本跑=\(bRanAfter)（B改前=\(bRanBefore)）"
    }
}

