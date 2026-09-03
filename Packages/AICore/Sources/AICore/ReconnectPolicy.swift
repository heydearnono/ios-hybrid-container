import Foundation

/// 断线重连策略。
///
/// 名字叫「重连」，实际语义是**重发整个请求**。这是被现实逼出来的：
/// SSE 规范提供了 `id:` + `Last-Event-ID` 的续传机制，但大模型厂商的流普遍**不给事件分配
/// 稳定 `id`**（本项目实现里 `SSEParser` 已经把 `id` 解析出来了，只是没人给）。
/// 没有 id 就无从告诉服务端「我收到哪儿了」，断线后只能从头再来一次。
///
/// 由此推出一条硬约束：**只在还没向下游吐出任何内容时才重连。**
/// 一旦吐过内容，重发会拿回一段全新的、与已吐内容无关的文本 —— 要么违反
/// 「每片必须是前一片的延展」这条不变量（UI 直接赋值会突然回退或跳变），
/// 要么得假装两段能接上（那是伪造连续性）。两者都比如实报错更糟。
///
/// 真正的流中途续传需要服务端配合（稳定事件 id，或幂等键 + 偏移量协议）。
/// 那是后端代理的设计问题，见 `docs/03-cloud-llm/client-architecture.md`。
public struct ReconnectPolicy: Sendable, Equatable {
    /// 首次失败之后**额外**尝试的次数。0 表示不重连。
    public var maximumRetries: Int
    /// 第一次重试前等多久。
    public var initialBackoff: Duration
    /// 每次重试的退避倍数。
    public var multiplier: Double
    /// 退避上限，防止指数增长把等待拖到分钟级。
    public var maximumBackoff: Duration
    /// 抖动比例：实际退避在 `[1-f, 1+f]` 倍之间随机取。
    ///
    /// 不加抖动的话，服务端一次抖动会让所有客户端在同一时刻一起重试，
    /// 把一次抖动放大成一波雪崩。测试里传 0 以获得确定性。
    public var jitterFraction: Double

    public init(
        maximumRetries: Int,
        initialBackoff: Duration = .milliseconds(500),
        multiplier: Double = 2,
        maximumBackoff: Duration = .seconds(4),
        jitterFraction: Double = 0.2
    ) {
        self.maximumRetries = max(0, maximumRetries)
        self.initialBackoff = initialBackoff
        self.multiplier = multiplier
        self.maximumBackoff = maximumBackoff
        self.jitterFraction = min(max(0, jitterFraction), 1)
    }

    /// 推荐值：重试 2 次，500ms 起指数退避，上限 4s。
    ///
    /// 次数刻意压得低。重试次数是**乘在服务端负载上**的：服务端正在雪崩时，
    /// 客户端多重试一次就是给它多加一倍压力。
    public static let `default` = ReconnectPolicy(maximumRetries: 2)

    /// 不重连。失败即如实抛出。
    public static let disabled = ReconnectPolicy(maximumRetries: 0, jitterFraction: 0)

    /// 只有**传输层瞬时故障**值得重试。
    ///
    /// 逐条说明为什么其余都不重试 —— 这些判断比代码本身重要：
    /// - `.unavailable`：凭证或配置问题，重试一万次也一样，该去刷新 token。
    /// - `.rateLimited`：服务端明确说了「慢点」，立刻重试是变本加厉。
    ///   `retryAfter` 已经如实带给调用方，等多久由调用方决定。
    /// - `.contextWindowExceeded` / `.guardrailViolation`：请求本身有问题，重发必然同样失败。
    /// - `.decodingFailure`：服务端吐了不认识的东西，是它的 bug，重试不会让它变对。
    /// - `.timedOut`：超时预算已经花掉了，再试一次只会让调用方等更久。
    /// - `.cancelled`：用户不想要了。
    /// - `.toolLoopLimitExceeded` / `.unsupportedCapability`：请求的形状本身就不成立。
    func allowsRetry(after error: ModelError) -> Bool {
        guard maximumRetries > 0 else { return false }
        switch error {
        case .network:
            return true
        case .unavailable, .contextWindowExceeded, .guardrailViolation, .rateLimited,
             .decodingFailure, .unsupportedLanguage, .timedOut, .cancelled,
             .toolLoopLimitExceeded, .unsupportedCapability, .underlying:
            return false
        }
    }

    /// `retryIndex` 从 0 开始计数（0 = 第一次重试前的等待）。
    func backoff(beforeRetry retryIndex: Int) -> Duration {
        let base = initialBackoff.seconds * pow(multiplier, Double(max(0, retryIndex)))
        let capped = min(base, maximumBackoff.seconds)
        guard jitterFraction > 0 else { return .seconds(capped) }
        let factor = Double.random(in: (1 - jitterFraction)...(1 + jitterFraction))
        return .seconds(capped * factor)
    }
}

extension ReconnectPolicy {
    /// 按策略反复执行 `attempt`，直到成功、错误不可重试、次数用尽，或任务被取消。
    ///
    /// `canRetry` 给调用方追加自己的判定：流式那条路径要额外要求「还没吐过内容」。
    ///
    /// 注意这里**不施加总时长上限** —— 重试全部发生在调用方超时预算之内，
    /// 由 `ModelRouter.withTimeout` 那一层统一切断。两处都管总时长会互相打架，
    /// 而且会让「到底谁把我掐了」变得难以排查。
    ///
    /// `isolation: #isolation` 让这个方法**继承调用方的隔离域**。不加这个参数，
    /// 从 actor 里传进来的闭包会被当成跨隔离域发送，严格并发检查直接报
    /// 「sending value of non-Sendable type risks causing data races」。
    func retrying<T>(
        timeout: Duration,
        isolation: isolated (any Actor)? = #isolation,
        canRetry: () -> Bool = { true },
        attempt: () async throws -> T
    ) async throws -> T {
        var retries = 0
        while true {
            do {
                return try await attempt()
            } catch {
                let mapped = CloudFailureMapper.modelError(from: error, timeout: timeout)
                guard retries < maximumRetries,
                      allowsRetry(after: mapped),
                      canRetry(),
                      !Task.isCancelled
                else { throw mapped }

                do {
                    try await Task.sleep(for: backoff(beforeRetry: retries))
                } catch {
                    // 退避期间被取消。如实报取消，不要把它伪装成原来那个网络错误。
                    throw ModelError.cancelled
                }
                retries += 1
            }
        }
    }
}
