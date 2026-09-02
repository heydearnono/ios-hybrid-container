import Foundation

/// 统一错误类型。
///
/// 端侧 `LanguageModelSession.GenerationError`（iOS 26.2 上恰好 9 个 case）与云端 HTTP/SSE
/// 失败必须收敛到同一组语义，否则调用方要为每个提供方各写一套错误处理。
/// 这里只保留**调用方需要分别应对**的类别，其余归入 `.underlying`。
public enum ModelError: Error, Equatable, Sendable {
    /// 提供方当前不可用。调用前应先查 `availability()`，但竞态仍可能让请求撞上这个错误。
    case unavailable(ModelUnavailableReason)

    /// 超出上下文窗口。端侧为每会话 4096 token（进出共用）。
    case contextWindowExceeded(limit: Int?)

    /// 内容被安全护栏拦下。端侧与云端都会有，且都可能误伤。
    case guardrailViolation

    /// 被限流。端侧仅在后台超限时出现。
    case rateLimited(retryAfter: Duration?)

    /// 结构化输出解析失败。复杂嵌套类型下是常见失败模式。
    case decodingFailure(detail: String)

    /// 语言或地区不受支持。
    case unsupportedLanguage(identifier: String)

    /// 网络层失败（仅云端）。
    case network(detail: String)

    /// 抽象层施加的硬超时被触发。
    ///
    /// 见到这个错误**不代表提供方出错**：端侧模型不可用时会挂死不抛错，此时唯一的表现就是超时。
    case timedOut(Duration)

    /// 请求被主动取消。
    case cancelled

    /// 未归类的底层错误。附上原始描述以便排查。
    case underlying(detail: String)
}

extension ModelError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "模型不可用：\(reason)"
        case .contextWindowExceeded(let limit):
            return "超出上下文窗口\(limit.map { "（上限 \($0) token）" } ?? "")"
        case .guardrailViolation:
            return "内容被安全护栏拦截"
        case .rateLimited:
            return "请求被限流"
        case .decodingFailure(let detail):
            return "结构化输出解析失败：\(detail)"
        case .unsupportedLanguage(let identifier):
            return "不支持的语言或地区：\(identifier)"
        case .network(let detail):
            return "网络错误：\(detail)"
        case .timedOut(let duration):
            return "请求超时（\(duration)）"
        case .cancelled:
            return "请求已取消"
        case .underlying(let detail):
            return detail
        }
    }
}
