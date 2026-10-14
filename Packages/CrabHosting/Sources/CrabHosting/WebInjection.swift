import Foundation

/// 页面开口前那段注入脚本的内容。**三端一字不差**(pro 的 M3「页面开口前那段脚本」),所以把它
/// 固定在一处,由各端把 origin 常量拼进去。
///
/// 形状(pro 定):一个立即执行函数 —— 先判 `location.origin` 是不是承载 origin(不是就返回),
/// 是则 `window.__CRAB__ = window.__CRAB__ || { origin, injected: 0 }`,随后 `injected++`。
/// **计数是自增不是重置**:注入跑了两次要看得出来(Android 的兜底路径可能与原生注入叠加)。
///
/// origin 由调用方从 `HostingOrigin.origin` 传进来,这里不另写字面量 —— 写了就成了第二处定义,
/// `SingleDefinitionTests` 会数出两处。
public enum WebInjection {
    public static func documentStartScript(origin: String) -> String {
        """
        (function () {
          if (location.origin !== '\(origin)') return;
          window.__CRAB__ = window.__CRAB__ || { origin: location.origin, injected: 0 };
          window.__CRAB__.injected++;
        })();
        """
    }
}
