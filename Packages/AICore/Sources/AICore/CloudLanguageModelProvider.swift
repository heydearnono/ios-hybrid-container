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

    public init(
        id: ModelProviderID = .cloud,
        configuration: CloudProviderConfiguration,
        credential: @escaping CloudCredentialProvider,
        session: URLSession = .shared
    ) {
        self.id = id
        self.configuration = configuration
        self.credential = credential
        self.session = session
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

    public func respond(to request: ModelRequest) async throws -> ModelResponse {
        let urlRequest = try await makeURLRequest(for: request, stream: false)

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
        guard let text = choice?.message?.content else {
            throw ModelError.decodingFailure(detail: "响应里没有 choices[0].message.content")
        }
        return ModelResponse(text: text, providerID: id)
    }

    // MARK: - 请求构造

    /// 非 private：流式实现在扩展文件里要复用。
    func makeURLRequest(
        for request: ModelRequest,
        stream: Bool
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

        var messages: [CloudWire.Message] = []
        if let instructions = request.systemInstructions, !instructions.isEmpty {
            messages.append(CloudWire.Message(role: "system", content: instructions))
        }
        messages.append(CloudWire.Message(role: "user", content: request.prompt))

        let body = CloudWire.ChatRequest(
            model: configuration.model,
            messages: messages,
            stream: stream,
            temperature: request.temperature,
            max_tokens: request.maximumResponseTokens
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
