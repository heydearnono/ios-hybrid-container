import Foundation

/// 取凭证的闭包。
///
/// **故意不接受字符串常量。** API Key 硬编码进 App 二进制等于公开发布 ——
/// ipa 可以被解包，字符串可以被 `strings` 直接扫出来，混淆只是提高门槛不是防护。
/// 正确形态是自建后端代理持有厂商 Key，设备侧只拿一个**用户态、可撤销、有有效期**的凭证，
/// 由这个闭包从 Keychain 或登录态里现取。
///
/// 返回 `nil` 表示当前没有可用凭证 —— provider 会如实报 `.unavailable(.notConfigured)`，
/// 而不是发一个注定 401 的请求。
public typealias CloudCredentialProvider = @Sendable () async throws -> String?

public struct CloudProviderConfiguration: Sendable {
    /// 代理或厂商端点的根地址，例如 `https://your-proxy.example.com`。
    public var baseURL: URL
    /// 模型名，原样透传给服务端。
    public var model: String
    /// chat completions 路径。留出可配是因为自建代理常挂在别的路径下。
    public var chatCompletionsPath: String
    /// 鉴权方案。绝大多数是 `Bearer`。
    public var authorizationScheme: String
    /// 额外请求头（厂商特有的版本号、租户标识等）。
    public var extraHeaders: [String: String]
    /// 断线重连策略。语义与限制见 `ReconnectPolicy` ——
    /// 关键一条：**只在还没吐出内容时才重连**。
    public var reconnect: ReconnectPolicy
    /// 工具调用循环的最大轮数。
    ///
    /// **云端的工具循环在客户端手里**（端侧在框架里），所以这个上限必须由我们自己设。
    /// 模型完全可能反复要求调同一个工具而永不收敛，每一轮都是一次真实计费请求 ——
    /// 没有上限就是一个能烧钱的死循环。超限如实抛 `.toolLoopLimitExceeded`，不静默截断。
    public var maximumToolIterations: Int
    /// 是否用 OpenAI 的 `strict` 模式下发工具 schema。
    ///
    /// 开启时参数会被服务端按 schema 强校验（每层 `additionalProperties: false`、
    /// 所有字段进 `required`、可选字段用 `["string","null"]` 表达），模型吐出的参数因此可信得多。
    /// ⚠️ 未验证：本项目没对任何真实厂商端点发过请求，部分自建网关可能不认 `strict` 字段 ——
    /// 遇到 400 先把这个关掉。
    public var usesStrictToolSchema: Bool

    public init(
        baseURL: URL,
        model: String,
        chatCompletionsPath: String = "/v1/chat/completions",
        authorizationScheme: String = "Bearer",
        extraHeaders: [String: String] = [:],
        reconnect: ReconnectPolicy = .default,
        maximumToolIterations: Int = 5,
        usesStrictToolSchema: Bool = true
    ) {
        self.baseURL = baseURL
        self.model = model
        self.chatCompletionsPath = chatCompletionsPath
        self.authorizationScheme = authorizationScheme
        self.extraHeaders = extraHeaders
        self.reconnect = reconnect
        self.maximumToolIterations = max(0, maximumToolIterations)
        self.usesStrictToolSchema = usesStrictToolSchema
    }

    var endpoint: URL {
        baseURL.appendingPathComponent(chatCompletionsPath.trimmingCharacters(in: ["/"]))
    }
}

/// 把 HTTP 状态码、响应体、以及 `URLSession` 抛出的错误收敛成 `ModelError`。
///
/// 单独拎出来是因为流式和非流式两条路径必须给出**一致**的错误语义 ——
/// 同一个 429 不能在流式下变成 `.underlying`。
enum CloudFailureMapper {
    /// 响应体截断长度。出错时服务端可能返回整页 HTML，原样塞进错误信息没有意义。
    static let bodyLimit = 500

    static func modelError(
        status: Int,
        retryAfterHeader: String?,
        body: String
    ) -> ModelError {
        let lowered = body.lowercased()
        let detail = truncate(body)

        if status == 429 {
            return .rateLimited(retryAfter: retryAfter(from: retryAfterHeader))
        }
        if status == 401 {
            return .unavailable(.notConfigured)
        }
        if status == 403 {
            return mentionsRegion(lowered)
                ? .unavailable(.regionUnsupported)
                : .unavailable(.notConfigured)
        }
        if mentionsContextWindow(lowered) {
            return .contextWindowExceeded(limit: parseContextLimit(from: body))
        }
        if mentionsContentFilter(lowered) {
            return .guardrailViolation
        }
        if (500...599).contains(status) {
            return .network(detail: "HTTP \(status)：\(detail)")
        }
        return .underlying(detail: "HTTP \(status)：\(detail)")
    }

    /// 把 `URLSession` / 解码 / 取消抛出的错误映射过来。
    ///
    /// `timeout` 只用于给 `URLError.timedOut` 填 Duration —— 那是 URLSession 自己的超时，
    /// 与抽象层强制施加的超时是两套机制，但对调用方是同一种语义。
    static func modelError(from error: any Error, timeout: Duration) -> ModelError {
        if let modelError = error as? ModelError { return modelError }
        if error is CancellationError { return .cancelled }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .timedOut(timeout)
            default:
                return .network(detail: "\(urlError.code.rawValue) \(urlError.localizedDescription)")
            }
        }
        if let decodingError = error as? DecodingError {
            return .decodingFailure(detail: "\(decodingError)")
        }
        return .underlying(detail: error.localizedDescription)
    }

    // MARK: - 内部

    static func truncate(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > bodyLimit else { return trimmed }
        return String(trimmed.prefix(bodyLimit)) + "…（已截断）"
    }

    /// `Retry-After` 允许秒数和 HTTP 日期两种格式。这里只解析秒数 ——
    /// 日期格式在 LLM 服务里极少见，解析它的复杂度换不来收益。解析不了就返回 nil。
    static func retryAfter(from header: String?) -> Duration? {
        guard let header = header?.trimmingCharacters(in: .whitespaces),
              let seconds = Double(header), seconds >= 0
        else { return nil }
        return .milliseconds(Int(seconds * 1000))
    }

    private static func mentionsRegion(_ lowered: String) -> Bool {
        ["unsupported_country", "country", "region", "territory"]
            .contains { lowered.contains($0) }
    }

    private static func mentionsContextWindow(_ lowered: String) -> Bool {
        ["context length", "context_length", "context window", "maximum context",
         "too many tokens", "reduce the length"]
            .contains { lowered.contains($0) }
    }

    private static func mentionsContentFilter(_ lowered: String) -> Bool {
        ["content_filter", "content filter", "content_policy", "safety",
         "responsible ai", "flagged"]
            .contains { lowered.contains($0) }
    }

    /// 尽力从错误文案里抠出 token 上限。**各厂商措辞不统一，抠不出来是常态**，
    /// 所以 `limit` 是可选的，调用方不能依赖它一定有值。
    static func parseContextLimit(from body: String) -> Int? {
        let markers = ["context length is", "context_length is", "maximum context length is",
                       "context window is"]
        let lowered = body.lowercased()
        for marker in markers {
            guard let range = lowered.range(of: marker) else { continue }
            let digits = lowered[range.upperBound...]
                .drop(while: { !$0.isASCII || !$0.isNumber })
                .prefix(while: { $0.isASCII && $0.isNumber })
            if let value = Int(digits) { return value }
        }
        return nil
    }
}
