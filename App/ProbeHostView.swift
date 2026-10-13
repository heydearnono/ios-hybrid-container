import SwiftUI
import WebKit
import OSLog
import CrabHosting

/// M2 探针宿主:把承载跑起来,页面侧六条断言的结果收回来,落盘给 `scripts/probe.sh` 回读。
///
/// 带 `--probe-m2` 启动参数时由 `CrabApp` 挂上。正常路径(HomeView)进不来 —— M1 的原生壳子那条分叉
/// 还在,这里是 M2 起多出来的一条。
struct ProbeHostView: View {
    @State private var model = M2ProbeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("M2 · 本地承载探针")
                .font(.headline)
            ProbeWebView(model: model)
                .border(.quaternary)
            ScrollView {
                Text(model.report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
        }
        .padding(12)
    }
}

/// 收结果、落盘、打日志。落盘那条是 `probe.sh` 回读的判据(`simctl get_app_container ... data` 直接读);
/// OSLog 那条顺带留一份,和 M4 靠日志判的那几条走同一条路。
@MainActor
@Observable
final class M2ProbeModel {
    private(set) var results: [String: String] = [:]
    private let logger = Logger(subsystem: "net.xiaoluzhu.crab", category: "probe")

    var report: String {
        M2Probe.slugs
            .map { "\($0) \(results[$0] ?? "（还没回来）")" }
            .joined(separator: "\n")
    }

    func record(_ parsed: [String: String]) {
        results = parsed
        var lines: [String] = []
        for slug in M2Probe.slugs {
            let value = parsed[slug] ?? "FAIL"
            let line = "\(slug) \(value)"
            lines.append(line)
            logger.log("CRAB-PROBE \(line, privacy: .public)")
        }
        write(lines.joined(separator: "\n") + "\n")
    }

    func recordError(_ message: String) {
        logger.log("CRAB-PROBE error \(message, privacy: .public)")
        write("# error \(message)\n")
    }

    private func write(_ text: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = docs.appendingPathComponent(M2Probe.resultFileName)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// 一个 WKWebView 把承载页加载起来。配置对象在创建实例时被拷贝,所以 handler 必须在创建之前挂上
/// (插队核实那一遍已踩过这条,见 docs/运行记录/插队核实-承载origin.md)。
private struct ProbeWebView: UIViewRepresentable {
    let model: M2ProbeModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        do {
            try M2Probe.materialize()
        } catch {
            model.recordError("materialize 失败: \(error)")
        }

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            CrabSchemeHandler(root: M2Probe.hostingRoot()),
            forURLScheme: HostingOrigin.scheme
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        webView.load(URLRequest(url: URL(string: HostingOrigin.origin + "/index.html")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let model: M2ProbeModel

        init(model: M2ProbeModel) { self.model = model }

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

        /// 断言里有 fetch,是异步的,所以轮询等页面把 __CRAB_PROBE_DONE__ 置上再取结果。
        private func poll(_ webView: WKWebView, attempt: Int) {
            let maxAttempts = 20 // 20 × 400ms ≈ 8s
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                let js = "(\(M2Probe.doneGlobal) === true) ? JSON.stringify(\(M2Probe.resultGlobal)) : ''"
                let value = try? await webView.evaluateJavaScript(js)
                let json = (value as? String) ?? ""
                if json.isEmpty {
                    if attempt + 1 >= maxAttempts {
                        model.recordError("超时:页面没有在限时内置上 \(M2Probe.doneGlobal)")
                    } else {
                        poll(webView, attempt: attempt + 1)
                    }
                    return
                }
                if let data = json.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode([String: String].self, from: data) {
                    model.record(parsed)
                } else {
                    model.recordError("结果 JSON 解析失败: \(json)")
                }
            }
        }
    }
}
