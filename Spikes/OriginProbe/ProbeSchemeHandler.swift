import Foundation
import WebKit

/// 承载目录的替身：入口 HTML 与一个同 origin 的子资源，都从这一个 handler 出。
///
/// M2 要的路径归一化、404 兜底、MIME 推断都不在这里 —— 这只是插队核实要用的最小素材。
final class ProbeSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let path = task.request.url?.path ?? "/"
        let (body, mime): (String, String) = switch path {
        case "/probe.js": ("window.__SUBRESOURCE__ = 'loaded';", "text/javascript")
        default: (Self.html, "text/html")
        }

        let data = Data(body.utf8)
        let response = URLResponse(
            url: task.request.url!,
            mimeType: mime,
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// 两个子帧一次问完：`data:` URL 那个，和它加载不起来时的退路 `sandbox` + `srcdoc`。
    /// 两个都让**子帧自报**，父页面不去读子帧 —— 子帧的 origin 是 opaque，父页面直读会被同源策略拦住。
    private static let html = #"""
    <!doctype html>
    <html lang="zh-Hans">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script>
      window.__frames = {};
      addEventListener('message', function (e) {
        if (e.data && e.data.from) { window.__frames[e.data.from] = e.data; }
      });
    </script>
    <script src="/probe.js"></script>
    <style>body{font:14px -apple-system;margin:8px}iframe{width:1px;height:1px;border:0}</style>
    </head>
    <body>
    <p id="here">origin probe</p>
    <iframe src="data:text/html,<script>parent.postMessage({from:'data',crab:typeof window.__CRAB__,origin:location.origin},'*')</script>"></iframe>
    <iframe sandbox="allow-scripts" srcdoc="<script>parent.postMessage({from:'srcdoc',crab:typeof window.__CRAB__,origin:location.origin},'*')</script>"></iframe>
    </body>
    </html>
    """#
}
