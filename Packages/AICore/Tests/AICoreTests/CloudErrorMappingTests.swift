import Foundation
import Testing

@testable import AICore

@Suite("云端错误映射与超时")
struct CloudErrorMappingTests {
    /// 默认关掉重连：这里测的是**错误语义**，5xx 之类可重试的失败若真去重试，
    /// 断言不会变但测试会白等几秒。重连行为由 `CloudReconnectTests` 覆盖。
    private func makeProvider(
        _ server: StubHTTPServer,
        token: String? = "test-token"
    ) -> CloudLanguageModelProvider {
        CloudLanguageModelProvider(
            configuration: CloudProviderConfiguration(
                baseURL: server.baseURL, model: "test-model", reconnect: .disabled
            ),
            credential: { token },
            session: URLSession(configuration: .ephemeral)
        )
    }

    /// 同一个失败在**流式和非流式两条路径**上必须给出同一个 `ModelError`。
    /// 这个辅助函数把两条路径都跑一遍。
    private func expectSameErrorOnBothPaths(
        reply: StubHTTPServer.Reply,
        _ check: (ModelError?, String) -> Void
    ) async throws {
        for path in ["非流式", "流式"] {
            let server = try StubHTTPServer(reply: reply)
            defer { server.stop() }
            let provider = makeProvider(server)
            let request = ModelRequest(prompt: "hi", timeout: .seconds(5))

            let error = await #expect(throws: ModelError.self) {
                if path == "非流式" {
                    _ = try await provider.respond(to: request)
                } else {
                    for try await _ in provider.streamResponse(to: request) {}
                }
            }
            check(error, path)
        }
    }

    // MARK: - HTTP 状态码

    @Test("401 映射为不可用（缺凭证）")
    func unauthorized() async throws {
        try await expectSameErrorOnBothPaths(
            reply: .json(status: 401, body: #"{"error":{"message":"invalid api key"}}"#)
        ) { error, path in
            #expect(error == .unavailable(.notConfigured), "\(path) 路径不符")
        }
    }

    @Test("403 提到国家/地区时映射为地区不支持")
    func regionUnsupported() async throws {
        try await expectSameErrorOnBothPaths(
            reply: .json(
                status: 403,
                body: #"{"error":{"code":"unsupported_country_region_territory"}}"#
            )
        ) { error, path in
            // 这条直接关系到 backlog 里「目标市场是否含中国大陆」那个问题：
            // 地区不可用必须能被区分出来，不能混进泛化的网络错误。
            #expect(error == .unavailable(.regionUnsupported), "\(path) 路径不符")
        }
    }

    @Test("429 映射为限流，并解析 Retry-After 秒数")
    func rateLimited() async throws {
        try await expectSameErrorOnBothPaths(
            reply: .json(status: 429, body: #"{"error":{"message":"slow down"}}"#,
                         headers: ["Retry-After": "2"])
        ) { error, path in
            #expect(error == .rateLimited(retryAfter: .seconds(2)), "\(path) 路径不符")
        }
    }

    @Test("上下文超限映射为 contextWindowExceeded，并尽力带上 token 上限")
    func contextWindowExceeded() async throws {
        let body = #"""
        {"error":{"message":"This model's maximum context length is 4096 tokens, however you requested 5000."}}
        """#
        try await expectSameErrorOnBothPaths(reply: .json(status: 400, body: body)) { error, path in
            #expect(error == .contextWindowExceeded(limit: 4096), "\(path) 路径不符")
        }
    }

    @Test("内容审查映射为 guardrailViolation")
    func contentFilterByStatus() async throws {
        try await expectSameErrorOnBothPaths(
            reply: .json(status: 400, body: #"{"error":{"code":"content_filter"}}"#)
        ) { error, path in
            #expect(error == .guardrailViolation, "\(path) 路径不符")
        }
    }

    @Test("5xx 映射为网络错误")
    func serverError() async throws {
        try await expectSameErrorOnBothPaths(
            reply: .json(status: 503, body: "upstream unavailable")
        ) { error, path in
            guard case .network = error else {
                Issue.record("\(path) 路径期望 .network，实际 \(String(describing: error))")
                return
            }
        }
    }

    // MARK: - HTTP 200 里藏的失败

    /// 只看状态码会把它当成功，用户拿到一个莫名截断的空回答。
    @Test("非流式：HTTP 200 但 finish_reason=content_filter 仍要报护栏拦截")
    func contentFilterInsideSuccessfulResponse() async throws {
        let server = try StubHTTPServer(
            reply: .json(body: StubHTTPServer.openAIResponse(
                content: "", finishReason: "content_filter"
            ))
        )
        defer { server.stop() }

        let error = await #expect(throws: ModelError.self) {
            _ = try await self.makeProvider(server).respond(to: ModelRequest(prompt: "hi"))
        }
        #expect(error == .guardrailViolation)
    }

    @Test("流式：HTTP 200 但 finish_reason=content_filter 仍要报护栏拦截")
    func contentFilterInsideStream() async throws {
        let frames = StubHTTPServer.openAIStreamFrames(
            deltas: ["开头"], finishReason: "content_filter"
        )
        let server = try StubHTTPServer(reply: .sse(frames: frames, perFrameDelay: .zero))
        defer { server.stop() }

        let error = await #expect(throws: ModelError.self) {
            for try await _ in self.makeProvider(server)
                .streamResponse(to: ModelRequest(prompt: "hi")) {}
        }
        #expect(error == .guardrailViolation)
    }

    // MARK: - 超时与取消

    @Test("服务端接受连接后一直不回：非流式必定在超时内失败")
    func hangingServerTimesOut() async throws {
        let server = try StubHTTPServer(reply: .hang)
        defer { server.stop() }

        let router = ModelRouter(primary: makeProvider(server))
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
        // 关键契约是「一定会返回」，不是「哪一层先超时」。
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("服务端一直不回：流式也必定在超时内失败")
    func hangingServerTimesOutWhileStreaming() async throws {
        let server = try StubHTTPServer(reply: .hang)
        defer { server.stop() }

        let router = ModelRouter(primary: makeProvider(server))
        let start = ContinuousClock.now

        let error = await #expect(throws: ModelError.self) {
            for try await _ in router.streamResponse(
                to: ModelRequest(prompt: "hi", timeout: .milliseconds(400))
            ) {}
        }
        guard case .timedOut = error else {
            Issue.record("期望 .timedOut，实际 \(String(describing: error))")
            return
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("消费者中途 break：流被正常拆除，不崩不挂")
    func earlyBreakTearsDownStream() async throws {
        let frames = StubHTTPServer.openAIStreamFrames(
            deltas: ["一", "二", "三", "四", "五"]
        )
        let server = try StubHTTPServer(
            reply: .sse(frames: frames, perFrameDelay: .milliseconds(30))
        )
        defer { server.stop() }

        var received = 0
        for try await _ in makeProvider(server).streamResponse(to: ModelRequest(prompt: "hi")) {
            received += 1
            if received == 2 { break }
        }
        #expect(received == 2)
    }
}

@Suite("云端错误映射：纯函数")
struct CloudFailureMapperTests {
    @Test("Retry-After 解析")
    func retryAfterParsing() {
        #expect(CloudFailureMapper.retryAfter(from: "2") == .seconds(2))
        #expect(CloudFailureMapper.retryAfter(from: " 1.5 ") == .milliseconds(1500))
        #expect(CloudFailureMapper.retryAfter(from: nil) == nil)
        // HTTP 日期格式不解析，如实返回 nil 而不是猜一个值
        #expect(CloudFailureMapper.retryAfter(from: "Wed, 21 Oct 2015 07:28:00 GMT") == nil)
        #expect(CloudFailureMapper.retryAfter(from: "-3") == nil)
    }

    @Test("上下文上限尽力解析，抠不出来时返回 nil")
    func contextLimitParsing() {
        #expect(CloudFailureMapper.parseContextLimit(
            from: "maximum context length is 8192 tokens") == 8192)
        #expect(CloudFailureMapper.parseContextLimit(
            from: "context window is 128000") == 128_000)
        // 各厂商措辞不统一，抠不出来是常态，调用方不能依赖 limit 一定有值
        #expect(CloudFailureMapper.parseContextLimit(from: "prompt too long") == nil)
    }

    @Test("超长响应体被截断，不把整页 HTML 塞进错误信息")
    func bodyTruncation() {
        let long = String(repeating: "x", count: 5000)
        let error = CloudFailureMapper.modelError(status: 502, retryAfterHeader: nil, body: long)
        guard case .network(let detail) = error else {
            Issue.record("期望 .network，实际 \(error)")
            return
        }
        #expect(detail.count < CloudFailureMapper.bodyLimit + 60)
        #expect(detail.contains("已截断"))
    }

    @Test("URLError 取消映射为 .cancelled，超时映射为 .timedOut")
    func urlErrorMapping() {
        #expect(CloudFailureMapper.modelError(
            from: URLError(.cancelled), timeout: .seconds(1)) == .cancelled)
        #expect(CloudFailureMapper.modelError(
            from: URLError(.timedOut), timeout: .seconds(7)) == .timedOut(.seconds(7)))
        #expect(CloudFailureMapper.modelError(
            from: CancellationError(), timeout: .seconds(1)) == .cancelled)
        // 已经是 ModelError 的原样透传，不要包一层丢掉语义
        #expect(CloudFailureMapper.modelError(
            from: ModelError.guardrailViolation, timeout: .seconds(1)) == .guardrailViolation)
    }
}
