import Foundation
import WebKit
import CrabHosting

/// M2 的承载:自定义 scheme + `WKURLSchemeHandler`。承载 origin 取 `HostingOrigin`(端内唯一定义),
/// 子资源经同一个 handler 从同一处提供,与主文档同 origin。
///
/// 判定全部调 `CrabHosting`(纯函数、有单测);这里只做 I/O:读文件、拼响应、兜 404。
///
/// 三条守则(都来自 pro 的 M2 iOS 一节与「要做到什么」):
/// 1. **先判 host。** `setURLSchemeHandler` 按 scheme 注册、不看 host,`crab://` 下任何 host 都进这里;
///    host 不是承载 host 的一律 404,否则别的 origin 也能从承载目录读文件。
/// 2. **未命中必须自己兜 404 + 固定标记 `INTERCEPTED`。** 承载 origin 上不得有请求真发到网上;
///    这个标记也是探针页「拦截」那条断言的判据。
/// 3. **越界(含编码 `..`)拒绝。** 归一化在 `HostingPath.resolve`,这里再加一道「落点必须在承载目录内」
///    的兜底。
final class CrabSchemeHandler: NSObject, WKURLSchemeHandler {
    /// 承载目录(承载的根)。它之外的文件一律取不到。
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            respondIntercepted(task, url: URL(string: HostingOrigin.origin)!)
            return
        }

        // 1. 先判 host。
        guard HostingPath.isHostingHost(url.host) else {
            respondIntercepted(task, url: url)
            return
        }

        // 2. 归一化;越界 → nil → 404。拿百分号编码后的 path,编码形式的 `..` 才拦得住。
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard let relative = HostingPath.resolve(percentEncodedPath: encodedPath) else {
            respondIntercepted(task, url: url)
            return
        }

        let target = relative.isEmpty ? "index.html" : relative
        let fileURL = root.appendingPathComponent(target).standardizedFileURL

        // 3. 兜底:归一化之后的落点必须仍在承载目录内。resolve 已挡住 `..` 越界,这里多一道防线
        // 兼挡符号链接一类归一化后才暴露的越界。
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard fileURL.path == root.path || fileURL.path.hasPrefix(rootPrefix) else {
            respondIntercepted(task, url: url)
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            respondIntercepted(task, url: url)
            return
        }

        respond(task, url: url, status: 200, data: data, mime: Self.mime(for: fileURL))
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// 未命中:404 + body 固定标记 `INTERCEPTED`。
    private func respondIntercepted(_ task: WKURLSchemeTask, url: URL) {
        respond(task, url: url, status: 404, data: Data("INTERCEPTED".utf8), mime: "text/plain")
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, data: Data, mime: String) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                // 同 origin 自取,这头只是让 fetch 读 body 时不被别的策略卡住。
                "Access-Control-Allow-Origin": HostingOrigin.origin,
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "png": "image/png"
        case "json": "application/json"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }
}
