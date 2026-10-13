import Foundation

/// 承载 origin 的**唯一定义处**。
///
/// pro 的 M2 要求承载 origin 在端内只定义一处,拦截点的 host 判定、注入范围判定、导航放行判定
/// 都从它派生,不得各处分别写字面量。字符串本身取自 pro 的取值表,本仓不自定 —— 连这段注释里也
/// 不复写它:复写的那一份会在改 origin 时过期,也会让下面那条检查数出两处。`scheme` 与 `host`
/// 一律从 `origin` 解析出来,不另写字面量 —— 这样全仓生产代码里
/// 这个 origin 串只出现这一行,`SingleDefinitionTests` 扫源码树钉着它只出现一次。
public enum HostingOrigin {
    /// 承载 origin。整串只在这里出现一次,改它只改这一处。取值来自 pro 的 README 取值表。
    public static let origin = "crab://ios.crab.invalid"

    private static let components: URLComponents = {
        guard let c = URLComponents(string: origin) else {
            fatalError("承载 origin 解析不出来:\(origin)")
        }
        return c
    }()

    /// scheme,喂给 `setURLSchemeHandler(_:forURLScheme:)`。从 origin 派生。
    public static let scheme: String = {
        guard let s = components.scheme, !s.isEmpty else {
            fatalError("承载 origin 里没有 scheme:\(origin)")
        }
        return s
    }()

    /// host,handler 先判这个 —— 非这个 host 的请求一律 404。从 origin 派生。
    public static let host: String = {
        guard let h = components.host, !h.isEmpty else {
            fatalError("承载 origin 里没有 host:\(origin)")
        }
        return h
    }()
}
