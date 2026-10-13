import Foundation

/// 承载请求的两道判定,都是纯函数,所以能在宿主 macOS 上单测,不必起模拟器。
/// handler(`App/CrabSchemeHandler.swift`)只做 I/O,判定一律调这里。
public enum HostingPath {
    /// handler 先判 host。`setURLSchemeHandler` 按 scheme 注册、不看 host,`crab://` 下任何 host
    /// 的请求都会进同一个 handler;host 不是承载 host 的一律当未命中,否则另一个 origin 也能从同一个
    /// 承载目录读到文件。判定从 `HostingOrigin.host` 派生。
    public static func isHostingHost(_ host: String?) -> Bool {
        host == HostingOrigin.host
    }

    /// 把请求路径归一化成承载目录内的相对路径;越界(含编码形式的 `..`)一律返回 nil,由 handler 兜 404。
    ///
    /// 传进来的应是**百分号编码后的** path(`URLComponents.percentEncodedPath`)。编码形式的 `..`
    /// (`%2e%2e%2f`)浏览器不会在 URL 层替你归一化,只有先解码再按段消解 `.` / `..` 才拦得住 ——
    /// 这正是 `escape-encoded` 那条断言要试的越界。
    ///
    /// 返回值:
    /// - 相对路径(如 `"index.html"`、`"a/b.png"`);空串表示根,handler 映射到入口 HTML
    /// - `nil`:路径想越出承载目录(有一个 `..` 在根上还要往上),拒绝
    public static func resolve(percentEncodedPath: String) -> String? {
        // 整段先解码:`%2e%2e` → `..`、`%2f` → `/`。解码后再按 `/` 切,plain `../` 与编码 `%2e%2e%2f`
        // 落到同一条消解逻辑上,编码那条就冒充不了合法段。
        let decoded = percentEncodedPath.removingPercentEncoding ?? percentEncodedPath

        var stack: [String] = []
        for segment in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                if stack.isEmpty {
                    return nil // 想越出承载目录
                }
                stack.removeLast()
            default:
                stack.append(String(segment))
            }
        }
        return stack.joined(separator: "/")
    }
}
