import SwiftUI
import WebKit

/// 两种 URL 形状各起一个 WKWebView，屏上同时看到，结果都进 `ProbeModel`。
struct OriginProbeView: View {
    @State private var model = ProbeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("插队核实 · 承载 origin 形态")
                .font(.headline)

            ForEach(OriginProbe.shapes) { shape in
                VStack(alignment: .leading, spacing: 4) {
                    Text(shape.url)
                        .font(.system(.caption, design: .monospaced))
                    ProbeWebView(shape: shape, model: model)
                        .frame(height: 56)
                        .background(.quaternary)
                }
            }

            ScrollView {
                Text(model.report)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }
}

/// 一个形状一个实例：配置对象在初始化时被拷贝，所以 handler 与注入脚本必须在创建之前挂上。
private struct ProbeWebView: UIViewRepresentable {
    let shape: OriginProbe.Shape
    let model: ProbeModel

    func makeCoordinator() -> Coordinator { Coordinator(shape: shape, model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.handler, forURLScheme: OriginProbe.scheme)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: OriginProbe.injectedScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        webView.load(URLRequest(url: URL(string: shape.url)!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let handler = ProbeSchemeHandler()
        private let shape: OriginProbe.Shape
        private let model: ProbeModel

        init(shape: OriginProbe.Shape, model: ProbeModel) {
            self.shape = shape
            self.model = model
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 子帧的 postMessage 是异步的，所以收两次：第一次拿主帧那几项，
            // 第二次给两个子帧留出回话的时间。
            collect(from: webView, after: .milliseconds(400))
            collect(from: webView, after: .seconds(2))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.record(shape: shape.id, json: "load-failed \(error)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            model.record(shape: shape.id, json: "provisional-failed \(error)")
        }

        private func collect(from webView: WKWebView, after delay: Duration) {
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                do {
                    let value = try await webView.evaluateJavaScript(OriginProbe.collectScript)
                    model.record(shape: shape.id, json: (value as? String) ?? String(describing: value))
                } catch {
                    model.record(shape: shape.id, json: "evaluate-failed \(error)")
                }
            }
        }
    }
}
