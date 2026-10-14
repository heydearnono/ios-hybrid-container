import SwiftUI
import WebKit
import OSLog
import CrabHosting

/// 探针宿主:把承载 + M3 配置跑起来,页面侧八条断言的结果收回来,落盘给 `scripts/probe.sh` 回读。
///
/// 带 `--probe` 启动参数时由 `CrabApp` 挂上。正常路径(HomeView)进不来。
struct ProbeHostView: View {
    @State private var model = CrabProbeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("M2/M3 探针")
                .font(.headline)
            ProbeWebView(model: model)
                .border(.quaternary)
            ScrollView {
                Text(model.report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
        }
        .padding(12)
    }
}

/// 收结果、落盘、打日志。落盘那条是 `probe.sh` 回读的判据;OSLog 顺带留一份。
@MainActor
@Observable
final class CrabProbeModel {
    private(set) var lines: [String] = []
    private let logger = Logger(subsystem: "net.xiaoluzhu.crab", category: "probe")

    var report: String { lines.joined(separator: "\n") }

    /// `parsed` 是八条 slug 的结果;`ua` / `ls` / `persist` 是 M3 那几行打印,接在结果文件末尾
    /// (以 `#` 起头,不与 slug 行相混,`probe.sh` 的 awk 只认 slug)。
    func record(parsed: [String: String], ua: String, ls: String, persist: String) {
        var out: [String] = []
        for slug in CrabProbe.slugs {
            let value = parsed[slug] ?? "FAIL"
            out.append("\(slug) \(value)")
            logger.log("CRAB-PROBE \(slug, privacy: .public) \(value, privacy: .public)")
        }
        out.append("# ua \(ua)")
        out.append("# localStorage \(ls)")
        out.append("# persist \(persist)")
        logger.log("CRAB-PROBE ua \(ua, privacy: .public)")
        logger.log("CRAB-PROBE persist \(persist, privacy: .public)")
        lines = out
        write(out.joined(separator: "\n") + "\n")
    }

    func recordError(_ message: String) {
        logger.log("CRAB-PROBE error \(message, privacy: .public)")
        lines = ["# error \(message)"]
        write("# error \(message)\n")
    }

    private func write(_ text: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? text.write(to: docs.appendingPathComponent(CrabProbe.resultFileName), atomically: true, encoding: .utf8)
    }
}

/// 一个 WKWebView 把承载页加载起来。配置经 `CrabWebViewConfig` 建好 —— 六项配置、注入、UA、
/// 带 identifier 的 store 都在创建之前落定;缩放与 http 拦截规则在创建之后、`load` 之前补上。
private struct ProbeWebView: UIViewRepresentable {
    let model: CrabProbeModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        do {
            try CrabProbe.materialize()
        } catch {
            model.recordError("materialize 失败: \(error)")
        }

        let configuration = CrabWebViewConfig.makeConfiguration(hostingRoot: CrabProbe.hostingRoot())
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        CrabWebViewConfig.disableZoom(on: webView)

        // http 拦截规则异步编译，编好再加载，保证规则在首次导航前就位。
        Task { @MainActor in
            await CrabWebViewConfig.applyHTTPBlockRule(to: webView)
            webView.load(URLRequest(url: URL(string: HostingOrigin.origin + "/index.html")!))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let model: CrabProbeModel

        init(model: CrabProbeModel) { self.model = model }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            poll(webView, attempt: 0)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.recordError("didFail: \(error)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            model.recordError("didFailProvisional: \(error)")
        }

        /// 断言里有 fetch 与子帧 postMessage,都是异步的,所以轮询等页面把 done 置上再取结果。
        private func poll(_ webView: WKWebView, attempt: Int) {
            let maxAttempts = 25 // 25 × 400ms = 10s
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                let js = """
                (\(CrabProbe.doneGlobal) === true)
                  ? JSON.stringify({ r: \(CrabProbe.resultGlobal), ua: \(CrabProbe.uaGlobal), ls: \(CrabProbe.lsGlobal), persist: \(CrabProbe.persistGlobal) })
                  : ''
                """
                let value = try? await webView.evaluateJavaScript(js)
                let json = (value as? String) ?? ""
                if json.isEmpty {
                    if attempt + 1 >= maxAttempts {
                        model.recordError("超时:页面没有在限时内置上 \(CrabProbe.doneGlobal)")
                    } else {
                        poll(webView, attempt: attempt + 1)
                    }
                    return
                }
                guard let data = json.data(using: .utf8),
                      let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let r = top["r"] as? [String: String] else {
                    model.recordError("结果 JSON 解析失败: \(json)")
                    return
                }
                let ua = (top["ua"] as? String) ?? "(absent)"
                let ls = (top["ls"] as? String) ?? "(absent)"
                let persist = (top["persist"] as? String) ?? "(absent)"
                model.record(parsed: r, ua: ua, ls: ls, persist: persist)
            }
        }
    }
}
