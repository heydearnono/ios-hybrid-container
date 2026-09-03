import Foundation
import Testing

@testable import AICore

@Suite("云端断线重连")
struct CloudReconnectTests {
    /// 退避压到毫秒级、抖动关掉：测的是**重试逻辑**，不是真的要等。
    private static let fastPolicy = ReconnectPolicy(
        maximumRetries: 2,
        initialBackoff: .milliseconds(10),
        multiplier: 2,
        maximumBackoff: .milliseconds(40),
        jitterFraction: 0
    )

    private func makeProvider(
        _ server: StubHTTPServer,
        policy: ReconnectPolicy = Self.fastPolicy
    ) -> CloudLanguageModelProvider {
        CloudLanguageModelProvider(
            configuration: CloudProviderConfiguration(
                baseURL: server.baseURL, model: "test-model", reconnect: policy
            ),
            credential: { "test-token" },
            session: URLSession(configuration: .ephemeral)
        )
    }

    private static let serverError = StubHTTPServer.Reply.json(status: 503, body: "upstream down")

    // MARK: - 非流式

    @Test("非流式：两次 5xx 之后成功，总共发三次请求")
    func retriesUntilSuccess() async throws {
        let server = try StubHTTPServer(replies: [
            Self.serverError,
            Self.serverError,
            .json(body: StubHTTPServer.openAIResponse(content: "第三次才通")),
        ])
        defer { server.stop() }

        let response = try await makeProvider(server).respond(to: ModelRequest(prompt: "hi"))
        #expect(response.text == "第三次才通")
        #expect(server.requests.count == 3)
    }

    @Test("非流式：一直 5xx 时用尽次数后如实报错，不会无限重试")
    func stopsAfterMaximumRetries() async throws {
        let server = try StubHTTPServer(reply: Self.serverError)
        defer { server.stop() }

        let error = await #expect(throws: ModelError.self) {
            _ = try await self.makeProvider(server).respond(to: ModelRequest(prompt: "hi"))
        }
        guard case .network = error else {
            Issue.record("期望 .network，实际 \(String(describing: error))")
            return
        }
        // 1 次首发 + 2 次重试。多一次都是白烧服务端。
        #expect(server.requests.count == 3)
    }

    @Test("不可重试的失败一次都不重试")
    func doesNotRetryUnretryableFailures() async throws {
        // 401 是凭证问题，重试一万次也一样
        let server = try StubHTTPServer(reply: .json(status: 401, body: "bad key"))
        defer { server.stop() }

        await #expect(throws: ModelError.unavailable(.notConfigured)) {
            _ = try await self.makeProvider(server).respond(to: ModelRequest(prompt: "hi"))
        }
        #expect(server.requests.count == 1)
    }

    // MARK: - 流式

    @Test("流式：首字节之前断连可以重连，重连后拿到完整回答")
    func reconnectsBeforeFirstToken() async throws {
        let server = try StubHTTPServer(replies: [
            Self.serverError,
            Self.serverError,
            .sse(frames: StubHTTPServer.openAIStreamFrames(deltas: ["你", "好"]),
                 perFrameDelay: .zero),
        ])
        defer { server.stop() }

        var chunks: [ModelResponseChunk] = []
        for try await chunk in makeProvider(server)
            .streamResponse(to: ModelRequest(prompt: "hi")) {
            chunks.append(chunk)
        }

        #expect(chunks.last?.cumulativeText == "你好")
        #expect(chunks.last?.isFinal == true)
        #expect(server.requests.count == 3)
    }

    /// **这条是整个重连设计的核心约束。**
    ///
    /// 重连的实际语义是「重发整个请求」，拿回来的是一段全新文本。如果已经有内容吐给了 UI，
    /// 重发就只有两个结局：让 UI 上的文字凭空跳变（违反「每片是前一片的延展」），
    /// 或者假装两段能接上（伪造连续性）。两者都比如实报错更糟。
    @Test("流式：已经吐出内容之后断连，如实报错而不是偷偷重发")
    func doesNotReconnectAfterDeliveringContent() async throws {
        // 声明 10000 字节却只发两帧就关连接 —— 一个明确的截断
        let frames = StubHTTPServer.openAIStreamFrames(deltas: ["半", "句"], finishReason: nil)
            .dropLast()  // 去掉 [DONE]，让它真的断在中间
        let server = try StubHTTPServer(replies: [
            .truncated(declaredLength: 10_000, pieces: Array(frames),
                       perPieceDelay: .milliseconds(10)),
            // 万一真去重连了，第二次会成功 —— 这样测试才能把「不该重连」抓出来
            .sse(frames: StubHTTPServer.openAIStreamFrames(deltas: ["完", "全", "不", "同"]),
                 perFrameDelay: .zero),
        ])
        defer { server.stop() }

        var chunks: [ModelResponseChunk] = []
        let error = await #expect(throws: ModelError.self) {
            for try await chunk in self.makeProvider(server)
                .streamResponse(to: ModelRequest(prompt: "hi")) {
                chunks.append(chunk)
            }
        }

        // 断连如实抛出，没有被重试掩盖
        guard case .network = error else {
            Issue.record("期望 .network，实际 \(String(describing: error))")
            return
        }
        // 只发过一次请求：内容已出门，重连被禁掉了
        #expect(server.requests.count == 1)
        // 已经吐出去的内容不回退、不跳变
        #expect(chunks.map(\.cumulativeText) == ["半", "半句"])
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(next.cumulativeText.hasPrefix(previous.cumulativeText))
        }
    }

    // MARK: - 重试与超时 / 取消的交互

    /// 重试不能变成绕过超时的后门。
    @Test("退避等待发生在超时预算之内，路由层照样能把它掐掉")
    func backoffStaysInsideTimeoutBudget() async throws {
        let server = try StubHTTPServer(reply: Self.serverError)
        defer { server.stop() }

        // 故意把退避设成 10 秒：只要退避不受超时约束，这个用例就会挂很久
        let slowBackoff = ReconnectPolicy(
            maximumRetries: 5, initialBackoff: .seconds(10),
            multiplier: 2, maximumBackoff: .seconds(30), jitterFraction: 0
        )
        let router = ModelRouter(primary: makeProvider(server, policy: slowBackoff))
        let start = ContinuousClock.now

        let error = await #expect(throws: ModelError.self) {
            _ = try await router.respond(
                to: ModelRequest(prompt: "hi", timeout: .milliseconds(400))
            )
        }
        guard case .timedOut = error else {
            Issue.record("期望 .timedOut，实际 \(String(describing: error))")
            return
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("退避期间被取消，报 .cancelled 而不是原来那个网络错误")
    func cancellationDuringBackoff() async throws {
        let server = try StubHTTPServer(reply: Self.serverError)
        defer { server.stop() }

        let slowBackoff = ReconnectPolicy(
            maximumRetries: 5, initialBackoff: .seconds(10),
            multiplier: 2, maximumBackoff: .seconds(30), jitterFraction: 0
        )
        let provider = makeProvider(server, policy: slowBackoff)

        let task = Task {
            try await provider.respond(to: ModelRequest(prompt: "hi", timeout: .seconds(60)))
        }
        // 等第一次请求失败、进入退避
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        let result = await task.result
        guard case .failure(let raw) = result else {
            Issue.record("期望失败，实际成功")
            return
        }
        #expect(raw as? ModelError == .cancelled)
    }
}

@Suite("重连策略：纯函数")
struct ReconnectPolicyTests {
    @Test("退避指数增长，并被上限截断")
    func backoffGrowsThenCaps() {
        let policy = ReconnectPolicy(
            maximumRetries: 10, initialBackoff: .milliseconds(100),
            multiplier: 2, maximumBackoff: .milliseconds(500), jitterFraction: 0
        )
        #expect(policy.backoff(beforeRetry: 0) == .milliseconds(100))
        #expect(policy.backoff(beforeRetry: 1) == .milliseconds(200))
        #expect(policy.backoff(beforeRetry: 2) == .milliseconds(400))
        // 800ms 会被 500ms 上限截住，不能让指数增长把等待拖到分钟级
        #expect(policy.backoff(beforeRetry: 3) == .milliseconds(500))
        #expect(policy.backoff(beforeRetry: 9) == .milliseconds(500))
    }

    @Test("抖动把退避散开，但不会散出 ±比例之外")
    func jitterStaysInRange() {
        let policy = ReconnectPolicy(
            maximumRetries: 1, initialBackoff: .milliseconds(100),
            multiplier: 1, maximumBackoff: .seconds(1), jitterFraction: 0.2
        )
        var seen: Set<Duration> = []
        for _ in 0..<50 {
            let backoff = policy.backoff(beforeRetry: 0)
            #expect(backoff >= .milliseconds(80))
            #expect(backoff <= .milliseconds(120))
            seen.insert(backoff)
        }
        // 抖动的意义就在于不同客户端不会撞在同一时刻，所以取值必须真的分散
        #expect(seen.count > 1)
    }

    @Test("只有传输层瞬时故障可重试")
    func retryableErrors() {
        let policy = ReconnectPolicy(maximumRetries: 2)
        #expect(policy.allowsRetry(after: .network(detail: "HTTP 503")))

        // 逐条都是有理由的，不是随手排除：见 ReconnectPolicy 的注释
        #expect(!policy.allowsRetry(after: .unavailable(.notConfigured)))
        #expect(!policy.allowsRetry(after: .rateLimited(retryAfter: .seconds(2))))
        #expect(!policy.allowsRetry(after: .contextWindowExceeded(limit: 4096)))
        #expect(!policy.allowsRetry(after: .guardrailViolation))
        #expect(!policy.allowsRetry(after: .decodingFailure(detail: "x")))
        #expect(!policy.allowsRetry(after: .timedOut(.seconds(1))))
        #expect(!policy.allowsRetry(after: .cancelled))
        #expect(!policy.allowsRetry(after: .underlying(detail: "x")))
    }

    @Test("次数为 0 时连可重试的错误也不重试")
    func disabledPolicyNeverRetries() {
        #expect(!ReconnectPolicy.disabled.allowsRetry(after: .network(detail: "boom")))
        #expect(ReconnectPolicy.disabled.maximumRetries == 0)
        // 负数不该变成「无限重试」
        #expect(ReconnectPolicy(maximumRetries: -3).maximumRetries == 0)
    }
}
