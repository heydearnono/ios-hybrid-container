import Foundation

/// 云端语言模型提供方。**这是当前唯一能被机器端到端验证的真实实现。**
///
/// 走真实 `URLSession`、真实 socket、真实 SSE 解析。测试打的是本地起的 stub 服务器，
/// 所以不需要任何厂商凭证就能验证全链路 —— 等后端就位，要改的只有 `baseURL` 和凭证来源。
///
/// 关于超时：这里只设置 `URLRequest.timeoutInterval`（传输层）。抽象层强制施加的硬超时
/// 由 `ModelRouter` 用 `withTimeout` 另外加一层 —— 传输层超时不覆盖「连上了但服务端
/// 挂着不吐字节」这类情况，两层都要有。
public actor CloudLanguageModelProvider: LanguageModelProvider {
    public nonisolated let id: ModelProviderID
    public nonisolated var isOnDevice: Bool { false }

    private let configuration: CloudProviderConfiguration
    private let credential: CloudCredentialProvider
    /// 非 private：流式实现在 `CloudLanguageModelProvider+Streaming.swift` 里要用。
    let session: URLSession
    let tools: ToolRegistry

    /// 非 private：同上。
    var reconnect: ReconnectPolicy { configuration.reconnect }
    var maximumToolIterations: Int { configuration.maximumToolIterations }

    public init(
        id: ModelProviderID = .cloud,
        configuration: CloudProviderConfiguration,
        credential: @escaping CloudCredentialProvider,
        session: URLSession = .shared,
        tools: ToolRegistry = .empty
    ) {
        self.id = id
        self.configuration = configuration
        self.credential = credential
        self.session = session
        self.tools = tools
    }

    /// **不发探测请求。** 只看有没有凭证。
    ///
    /// 理由：为了回答「可用吗」而先打一次真实请求，会带来额外延迟和费用，而且服务端
    /// 此刻可用也不保证下一秒可用 —— 竞态无法靠探测消除，只能靠请求本身的错误处理兜住。
    /// 所以这里只拦住「明显不可能成功」的情况。
    public func availability() async -> ModelAvailability {
        do {
            guard let token = try await credential(), !token.isEmpty else {
                return .unavailable(.notConfigured)
            }
            return .available
        } catch {
            return .unavailable(.notConfigured)
        }
    }

    // MARK: - 非流式

    /// 非流式请求。可重试的失败按 `ReconnectPolicy` 退避重发；模型要求调工具时**自己跑循环**。
    ///
    /// 非流式这条路径没有「已经吐过内容」的顾虑 —— 要么整个回答拿到，要么什么都没拿到，
    /// 所以重发是干净的。流式那条路径的额外约束见 `ReconnectPolicy`。
    public func respond(to request: ModelRequest) async throws -> ModelResponse {
        var messages = Self.initialMessages(for: request)
        var invocations: [ToolCallResult] = []
        var roundsUsed = 0

        while true {
            let isFirstRound = roundsUsed == 0
            let round = try await reconnect.retrying(timeout: request.timeout) {
                try await self.respondOnce(
                    request, messages: messages, isFirstRound: isFirstRound)
            }

            guard !round.toolCalls.isEmpty else {
                guard let text = round.text else {
                    throw ModelError.decodingFailure(
                        detail: "响应里既没有 choices[0].message.content 也没有 tool_calls")
                }
                return ModelResponse(
                    text: text, providerID: id, toolInvocations: invocations)
            }
            guard roundsUsed < maximumToolIterations else {
                throw ModelError.toolLoopLimitExceeded(limit: maximumToolIterations)
            }
            roundsUsed += 1

            messages.append(.assistant(content: round.text, toolCalls: round.toolCalls))
            let results = await tools.execute(round.toolCalls)
            invocations.append(contentsOf: results)
            messages.append(contentsOf: results.map { CloudWire.Message.toolResult($0) })
        }
    }

    /// 一轮的产出。`text` 与 `toolCalls` 可以同时非空 —— spec 不禁止边说边调。
    struct RoundOutcome {
        var text: String?
        var toolCalls: [ToolCallRequest] = []
    }

    private func respondOnce(
        _ request: ModelRequest,
        messages: [CloudWire.Message],
        isFirstRound: Bool
    ) async throws -> RoundOutcome {
        let urlRequest = try await makeURLRequest(
            request, messages: messages, stream: false, isFirstRound: isFirstRound)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw CloudFailureMapper.modelError(from: error, timeout: request.timeout)
        }

        try Self.validate(response: response, body: data)

        let decoded: CloudWire.ChatResponse
        do {
            decoded = try JSONDecoder().decode(CloudWire.ChatResponse.self, from: data)
        } catch {
            throw ModelError.decodingFailure(detail: "响应体不是预期的 JSON：\(CloudFailureMapper.truncate(String(decoding: data, as: UTF8.self)))")
        }

        // HTTP 200 里也可能藏着 error 载荷。
        if let payload = decoded.error {
            throw Self.modelError(fromPayload: payload)
        }

        let choice = decoded.choices?.first
        if let reason = choice?.finish_reason,
           CloudWire.contentFilterFinishReasons.contains(reason) {
            throw ModelError.guardrailViolation
        }
        return RoundOutcome(
            text: choice?.message?.content,
            toolCalls: (choice?.message?.tool_calls ?? []).map(ToolCallRequest.init))
    }

    // MARK: - 请求构造

    /// 非 private：流式实现在扩展文件里要复用。
    static func initialMessages(for request: ModelRequest) -> [CloudWire.Message] {
        var messages: [CloudWire.Message] = []
        if let instructions = request.systemInstructions, !instructions.isEmpty {
            messages.append(CloudWire.Message(role: "system", content: instructions))
        }
        messages.append(CloudWire.Message(role: "user", content: request.prompt))
        return messages
    }

    /// 非 private：流式实现在扩展文件里要复用。
    ///
    /// `isFirstRound` 决定 `tool_choice` 要不要下发：**强制类的选择只在第一轮生效**。
    /// 否则 `.required` 会让模型每一轮都必须再调一次工具，永远轮不到它给出答案 ——
    /// 循环只会撞上 `maximumToolIterations`。
    func makeURLRequest(
        _ request: ModelRequest,
        messages: [CloudWire.Message],
        stream: Bool,
        isFirstRound: Bool
    ) async throws -> URLRequest {
        guard let token = try await credential(), !token.isEmpty else {
            throw ModelError.unavailable(.notConfigured)
        }

        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout.seconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(
            stream ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        urlRequest.setValue(
            "\(configuration.authorizationScheme) \(token)",
            forHTTPHeaderField: "Authorization"
        )
        for (key, value) in configuration.extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let strict = configuration.usesStrictToolSchema
        let body = CloudWire.ChatRequest(
            model: configuration.model,
            messages: messages,
            stream: stream,
            temperature: request.temperature,
            max_tokens: request.maximumResponseTokens,
            // 没有工具时整个字段省掉，`tool_choice` 也跟着省 —— 服务端在无 tools 时
            // 本来就把它当 `none`，发过去只是噪音。
            tools: tools.isEmpty ? nil : tools.all.map { .init($0, strict: strict) },
            tool_choice: tools.isEmpty || !isFirstRound
                ? nil : CloudWire.ToolChoiceWire(request.toolChoice)
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    // MARK: - 错误判定（流式与非流式共用，保证语义一致）

    static func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        throw CloudFailureMapper.modelError(
            status: http.statusCode,
            retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
            body: String(decoding: body, as: UTF8.self)
        )
    }

    static func modelError(fromPayload payload: CloudWire.ErrorPayload) -> ModelError {
        let text = [payload.type, payload.code, payload.message]
            .compactMap { $0 }
            .joined(separator: " ")
        return CloudFailureMapper.modelError(status: 400, retryAfterHeader: nil, body: text)
    }
}

extension Duration {
    /// `URLRequest.timeoutInterval` 要 `TimeInterval`，而 `Duration` 只给整数分量。
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
