import Foundation
import WebKit

/// 插队核实 · 承载 `origin` 形态与 `data:` iframe
///
/// `pro` 的开工文档要求 **M1 一过立刻插队、不等 M2 开工**：iOS 那条是自定义 scheme 的
/// `location.origin` 到底是不是 opaque，带 host 与不带 host 两种形状各试一次；
/// 三端共有那条是 `data:` iframe 加不加载得起来，不行就地试 `sandbox` + `srcdoc` 退路。
///
/// **这不是 M2 的承载实现。** 承载 scheme 常量要在 M2 才落成端内唯一一处并配一条可执行检查；
/// 这里刻意写了两个字面量 —— 要比的就是两种形状，收成一处就没法比了。
/// 注入的那段脚本也刻意不带 M3 要求的 origin 自判：现在要看的是它在哪些帧里跑过。
enum OriginProbe {
    /// scheme 取值来自 `pro` 的取值表。
    static let scheme = "crab"

    struct Shape: Identifiable, Sendable {
        let id: String
        let url: String
    }

    static let shapes: [Shape] = [
        Shape(id: "with-host", url: "crab://app/index.html"),
        Shape(id: "no-host", url: "crab:///index.html"),
    ]

    /// 原生在页面开口前注入的那一段。计数是自增不是重置 —— 跑了两次要看得出来。
    static let injectedScript = """
    (function () {
      window.__CRAB__ = window.__CRAB__ || { origin: location.origin, injected: 0 };
      window.__CRAB__.injected++;
    })();
    """

    /// 页面侧一次性把要问的都答完。返回 JSON 字符串，原生只负责搬运，不解释。
    static let collectScript = """
    JSON.stringify({
      origin: location.origin,
      href: location.href,
      baseURI: document.baseURI,
      isSecureContext: window.isSecureContext,
      storage: (function () {
        try {
          localStorage.setItem('probe', 'ok');
          var v = localStorage.getItem('probe');
          localStorage.removeItem('probe');
          return v === 'ok' ? 'ok' : 'mismatch:' + v;
        } catch (e) { return 'throw:' + e.name; }
      })(),
      subresource: typeof window.__SUBRESOURCE__ === 'undefined'
        ? 'absent' : String(window.__SUBRESOURCE__),
      injected: window.__CRAB__ ? window.__CRAB__.injected : 'absent',
      injectedOrigin: window.__CRAB__ ? String(window.__CRAB__.origin) : 'absent',
      frames: window.__frames || {}
    })
    """
}
